## PinnedScope RAII guard for pin-scoped retire.
##
## `PinnedScope[MT, CC]` is the recommended high-level entry point for the
## pin/retire/unpin cycle, replacing the now-deprecated block-form sugar.
## Construct via `pinScope(unpinned(handle))`; destruction (block exit, scope
## end, explicit `=destroy`) drives the underlying `EpochGuardContext`
## through `unpin` (and, if signaled, `acknowledge`) and finally `close`,
## clearing the slot's `pinned` flag.
##
## The typestate carries two static generic-param axes:
##
## - `MT: static int` — capacity of the manager's thread array.
## - `CC: static PinScopeCardinality = ccSingle` — consumer-cardinality
##   phantom mirroring `DebraManager` / `ThreadHandle` / `EpochGuardContext`
##   / `RetireContext`. Default `ccSingle` matches the 0.7.x call shape.
##
## Codegen-emitted helpers (=copy hooks, `state()` procs, `$` overloads,
## `match` macros) inherit `CC = ccSingle` via the typestate macro's
## `defaults:` body section (typestates 0.9.2+).
##
## ## States
##
## * `PinnedScopeAlive` — the scope holds a `Pinned[MT, CC]` value and is
##   eligible for `retireOnCAS` / `retireOnPublish`.
## * `PinnedScopeDestroyed` — terminal state reached via `=destroy`. The
##   inner `Pinned` was moved out and driven to `Closed` through the
##   `unpin` / `acknowledge` / `close` chain.
##
## ## Retire methods
##
## * `retireOnCAS` — atomically swap a published pointer, retire the
##   displaced value. Multi-writer safe (the CAS arbitrates).
## * `retireOnPublish` — store-and-retire. **FOOT-GUN: single-writer
##   required (DR-S4).** nim-debra cannot statically verify that the caller's
##   atomic is single-writer. Under multi-writer use, the displaced value
##   may be retired concurrently and double-freed on reclamation. Use
##   `retireOnCAS` for the multi-writer-safe form.
##
## ## Pitfalls
##
## * Do NOT call `pinScope` while the thread is already pinned at the slot
##   level. A `doAssert` guards in release builds.
## * `PinnedScope` is non-copyable (`=copy` is `{.error.}`). Move it
##   between scopes if you must transfer ownership; the destructor runs
##   exactly once at the final owner's scope end.
## * `=wasMoved` marks the source as `consumed = true`; a re-entrant
##   `=destroy` on a moved-from value is a no-op.
##
## ## See also
##
## * `debra/typestates/guard.pin`_ / `unpin`_ / `acknowledge`_ / `close`_ —
##   the underlying `EpochGuardContext` transitions driven internally.
## * `debra/typestates/retire`_ — `RetireReady` / `Retired` rotation used
##   inside the retire methods.

import ../atomics
import ../types
import ../limbo
import ./cardinality
import ./guard
import ./retire
import typestates

export cardinality

type
  PinnedScopeContext*[MT: static int, CC: static PinScopeCardinality = ccSingle] = object of RootObj
    # phantom-only base; the user-visible PinnedScope carries the live data.

  PinnedScopeAlive*[MT: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct PinnedScopeContext[MT, CC]

  PinnedScopeDestroyed*[MT: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct PinnedScopeContext[MT, CC]

typestate PinnedScopeLifecycle[MT: static int, CC: static PinScopeCardinality]:
  inheritsFromRootObj = true
  defaults:
    CC:
      ccSingle
  states:
    PinnedScopeAlive[MT, CC]
    PinnedScopeDestroyed[MT, CC]
  initial:
    PinnedScopeAlive[MT, CC]
  terminal:
    PinnedScopeDestroyed[MT, CC]
  transitions:
    PinnedScopeAlive[MT, CC] -> PinnedScopeDestroyed[MT, CC]

type PinnedScope*[MT: static int, CC: static PinScopeCardinality = ccSingle] {.
  PinnedScopeLifecycle: PinnedScopeAlive
.} = object
  state*: Pinned[MT, CC]
  consumed*: bool

proc pinScope*[MT: static int, CC: static PinScopeCardinality](
    u: sink Unpinned[MT, CC]
): PinnedScope[MT, CC] {.raises: [].} =
  ## Construct a pinned scope. RAII-style: destruction unpins.
  ##
  ## Renamed from `pin` (the plan's original spelling) to `pinScope` to
  ## avoid a proc-name collision with `guard.pin` (both consume
  ## `Unpinned[MT, CC]` but return different result typestates, and Nim
  ## cannot disambiguate by return type at standard call sites).
  ##
  ## ## Foot-gun: do NOT call `pinScope` while already pinned at the slot
  ## level. A `doAssert` guards in release builds. Use `PinnedScope`
  ## per-thread; the guard catches double-pin from re-entrant code.
  runnableExamples:
    import debra
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    block:
      var scope = pinScope(unpinned(handle))
      # scope is alive; on block exit =destroy runs and unpins.
      discard scope.consumed

  # NOTE: not marked {.transition.} — typestates 0.9.2 forbids cross-module
  # transitions, and EpochGuardContext belongs to guard.nim. The inner
  # u.pin() drives EpochGuardContext.Unpinned -> Pinned in-module. This
  # outer constructor produces a value in PinnedScopeLifecycle's initial
  # state PinnedScopeAlive via the
  # {.PinnedScopeLifecycle: PinnedScopeAlive.} attachment pragma.
  # `u` (a sink param) is READ, not consumed, here: converting to
  # EpochGuardContext is a non-destructive field read, and Nim's move
  # analysis keeps `u` live because `u.pin()` below is its sole consumer. The
  # handle must be read BEFORE pin(), since pin() sets the slot `pinned` flag
  # that the re-entrancy doAssert checks.
  let handleVal = EpochGuardContext[MT, CC](u).handle
  let idx = handleVal.idx
  doAssert(
    not handleVal.manager.threads[idx].pinned.load(moAcquire),
    "pinScope: thread already pinned (re-entrant pin?)",
  )
  PinnedScope[MT, CC](state: u.pin(), consumed: false)

proc retireOnCAS*[MT: static int, CC: static PinScopeCardinality, T: ptr | pointer](
    scope: var PinnedScope[MT, CC],
    atomic: var Atomic[T],
    expected: var T,
    desired: T,
    dtor: Destructor,
): bool {.discardable, raises: [].} =
  ## Atomically swap a published pointer and retire the displaced value.
  ##
  ## Returns true on CAS success (after rotating `scope.state` through
  ## `RetireReady` -> `Retired` -> `Pinned`). Returns false on CAS
  ## failure, leaving `scope.state` unchanged.
  ##
  ## Callable under any `CC` (DR-S3).
  ##
  ## `expected` is an in/out parameter: on CAS failure it is updated to the
  ## value actually observed (as in stdlib `compareExchange`), so a retry
  ## loop need not re-load before the next attempt.
  ##
  ## **`T` contract:** `T` is constrained to `ptr | pointer` (a raw pointer
  ## type, `ptr X` or `pointer`). The displaced value is `cast[pointer]` and
  ## reclaimed via `dtor`, so instantiating over a `ref` is rejected at
  ## compile time — refs are GC-managed and would double-free on manual
  ## reclamation. Generic wrappers forwarding their own element type must
  ## likewise admit only pointer-shaped types.
  # `expected` is an in/out param (matches stdlib `compareExchange`): on CAS
  # failure `compareExchange` writes the observed value back into it so a
  # caller retry loop need not re-load. On success it is unchanged and still
  # holds the displaced value we retire below.
  if atomic.compareExchange(expected, desired, moAcquireRelease, moAcquire):
    # Rotate: Pinned -> RetireReady (BY-VALUE per DR-P3) -> Retired -> Pinned.
    # retireReady is by-value over Pinned (does not consume scope.state in
    # the typestate sense); the resulting RetireReady is the sink param for
    # retire, which produces a fresh Retired. pinnedFromRetired rebuilds a
    # Pinned in the same epoch so the scope remains usable for further
    # retires inside the same pinned section.
    let p = cast[pointer](expected)
    if p != nil:
      var ready = retireReady(scope.state)
      let retired = ready.retire(p, dtor)
      scope.state = pinnedFromRetired(retired)
    return true
  return false

proc retireOnPublish*[MT: static int, CC: static PinScopeCardinality, T: ptr | pointer](
    scope: var PinnedScope[MT, CC], atomic: var Atomic[T], desired: T, dtor: Destructor
) {.raises: [].} =
  ## **FOOT-GUN — single-writer required (DR-S4).**
  ##
  ## Stores ``desired`` into ``atomic`` and retires the displaced value.
  ## nim-debra cannot statically verify that ``atomic`` is single-writer;
  ## under multi-writer use, the displaced value may be retired
  ## concurrently and double-freed on reclamation.
  ##
  ## Use `retireOnCAS`_ for the multi-writer-safe form.
  ##
  ## **`T` contract:** `T` is constrained to `ptr | pointer` (a raw pointer
  ## type, `ptr X` or `pointer`). The displaced value is `cast[pointer]` and
  ## reclaimed via `dtor`, so instantiating over a `ref` is rejected at
  ## compile time — refs are GC-managed and would double-free on manual
  ## reclamation. Generic wrappers forwarding their own element type must
  ## likewise admit only pointer-shaped types.
  # Single-writer fast path (DR-S4): the plain acquire-load + release-store is
  # deliberate and cheaper than an `exchange` RMW. Under the documented
  # single-writer contract no other thread writes `atomic`, so the loaded
  # pointer is exactly the value the store displaces — an `exchange` would add
  # a StoreLoad/RMW cost on this hot path for no benefit. Callers needing
  # multi-writer safety must use `retireOnCAS` (the CAS form above), not a
  # "hardened" variant of this foot-gun.
  let displaced = atomic.load(moAcquire)
  atomic.store(desired, moRelease)
  let p = cast[pointer](displaced)
  if p != nil:
    var ready = retireReady(scope.state)
    let retired = ready.retire(p, dtor)
    scope.state = pinnedFromRetired(retired)

proc `=destroy`*[MT: static int, CC: static PinScopeCardinality](
    scope: var PinnedScope[MT, CC]
) {.destructorTransition: PinnedScopeAlive -> PinnedScopeDestroyed, raises: [].} =
  ## Destructor: drives the inner `Pinned` through `unpin` (and, if the
  ## thread was signaled, `acknowledge`) and finally `close`, clearing the
  ## slot's `pinned` flag.
  ##
  ## A `=wasMoved`-marked scope (i.e. one whose value was moved into
  ## another scope) is consumed; this destructor is a no-op for it.
  if not scope.consumed:
    var p = move(scope.state)
    var res = p.unpin()
    match res:
      Unpinned(u):
        discard u.close()
      Neutralized(n):
        discard n.acknowledge().close()

proc `=copy`*[MT: static int, CC: static PinScopeCardinality](
  dest: var PinnedScope[MT, CC], src: PinnedScope[MT, CC]
) {.error.}

proc `=wasMoved`*[MT: static int, CC: static PinScopeCardinality](
    scope: var PinnedScope[MT, CC]
) =
  ## Mark the moved-from value as consumed so a re-entrant `=destroy` is a
  ## no-op. Do NOT touch `scope.state`; the move source is unreachable by
  ## the type system, and the destination owns the underlying `Pinned`.
  scope.consumed = true
