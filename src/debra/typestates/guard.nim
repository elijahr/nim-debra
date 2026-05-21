## EpochGuard typestate for pin/unpin lifecycle.
##
## Ensures threads properly enter/exit critical sections.
##
## The typestate carries two static generic-param axes:
##
## - `MaxThreads: static int` — capacity of the manager's thread array.
## - `CC: static PinScopeCardinality = ccSingle` — consumer-cardinality
##   phantom mirroring `DebraManager` / `ThreadHandle` /
##   `RegistrationContext`. Default `ccSingle` matches the 0.7.x call
##   shape, so existing call sites that spell only `MaxThreads` continue
##   to bind cleanly.
##
## Codegen-emitted helpers (variant type `UnpinResult`, `=copy` hooks,
## `state()` procs, `$` overloads, `match` macros) inherit `CC = ccSingle`
## via the typestate macro's `defaults:` body section (typestates 0.9.2+).
##
## ## States
##
## * `Unpinned` — outside a critical section. Constructed via `unpinned`.
## * `Pinned` — inside a critical section, epoch captured.
## * `Neutralized` — was Pinned, then signaled; must `acknowledge`
##   before re-pinning.
## * `Closed` — terminal state reached only by the destructor path of
##   `PinnedScope` (or the deprecated `withPin` finalizer). User code
##   SHOULD NOT call `close` directly; rely on `PinnedScope` to drive
##   the lifecycle. `close` performs no atomic operations — the slot's
##   `pinned` / `neutralized` flags were already cleared by the
##   preceding `unpin` (or `unpin + acknowledge`) call.
##
## ## Pitfalls
##
## * The `Unpinned` -> `Pinned` -> `Unpinned`/`Neutralized` typestate sequence
##   must be respected. Calling `pin` on a handle that is already pinned at
##   the slot level (the manager's `threads[idx].pinned` flag is true) leaves
##   the slot inconsistent. Use `withPin` (in `debra/convenience`) for the
##   common path; reach for the typestate API only when you need finer control.
## * If `unpin` returns `Neutralized`, the thread was signaled while inside
##   the critical section. Call `acknowledge` before re-pinning. Skipping
##   `acknowledge` will leave the slot's `neutralized` flag set, and the
##   next `pin`/`unpin` cycle will misreport state.
## * `Pinned[MT, CC]` carries the captured `epoch` field; do not mutate the
##   manager's global epoch under the assumption a particular `Pinned` value
##   tracks it. Advance the manager epoch on the worker side, then re-pin to
##   refresh.
##
## ## See also
##
## * `debra/convenience.withPin`_ - the recommended high-level wrapper.
## * `debra/typestates/retire`_ - `RetireReady` constructed from `Pinned`.

import ../atomics
import typestates

import ../types

# `PinScopeCardinality` reaches this module via `../types` (re-exported
# from `./cardinality`).

type
  EpochGuardContext*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] = object of RootObj
    handle*: ThreadHandle[MaxThreads, CC]
    epoch*: uint64

  Unpinned*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct EpochGuardContext[MaxThreads, CC]

  Pinned*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct EpochGuardContext[MaxThreads, CC]

  Neutralized*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct EpochGuardContext[MaxThreads, CC]

  Closed*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct EpochGuardContext[MaxThreads, CC]

typestate EpochGuardContext[MaxThreads: static int, CC: static PinScopeCardinality]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across typestate boundaries
  defaults:
    CC:
      ccSingle
  states:
    Unpinned[MaxThreads, CC]
    Pinned[MaxThreads, CC]
    Neutralized[MaxThreads, CC]
    Closed[MaxThreads, CC]
  terminal:
    Closed[MaxThreads, CC]
  transitions:
    Unpinned[MaxThreads, CC] -> Pinned[MaxThreads, CC]
    Pinned[MaxThreads, CC] ->
      Unpinned[MaxThreads, CC] | Neutralized[MaxThreads, CC] as
      UnpinResult[MaxThreads, CC]
    Neutralized[MaxThreads, CC] -> Unpinned[MaxThreads, CC]
    Unpinned[MaxThreads, CC] -> Closed[MaxThreads, CC]

proc unpinned*[MaxThreads: static int, CC: static PinScopeCardinality](
    handle: ThreadHandle[MaxThreads, CC]
): Unpinned[MaxThreads, CC] =
  ## Create unpinned epoch guard context.
  Unpinned[MaxThreads, CC](EpochGuardContext[MaxThreads, CC](handle: handle, epoch: 0))

proc pin*[MaxThreads: static int, CC: static PinScopeCardinality](
    u: sink Unpinned[MaxThreads, CC]
): Pinned[MaxThreads, CC] {.transition.} =
  ## Enter critical section. Blocks reclamation of current epoch.
  runnableExamples:
    import debra
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let pinned = unpinned(handle).pin()
    discard pinned.unpin()
  var ctx = EpochGuardContext[MaxThreads, CC](u)
  let mgr = ctx.handle.manager
  let idx = ctx.handle.idx

  ctx.epoch = mgr.globalEpoch.load(moAcquire)
  mgr.threads[idx].neutralized.store(false, moRelease)
  mgr.threads[idx].epoch.store(ctx.epoch, moRelease)
  # Publication via an SC read-modify-write on `pinned`. Semantically
  # equivalent to `pinned.store(true, moRelease)` followed by an SC
  # thread fence: the RMW participates in the C11 SC total order S, so
  # subsequent loads in this thread are ordered after any reclaimer's SC
  # operations that precede this RMW in S, and prior stores in this
  # thread (`epoch.store`, `neutralized.store`) are HB-before any
  # reclaimer load that observes this RMW.
  #
  # We use an exchange (rather than `store`/`exchange`-with-fence) for a
  # specific TSAN reason: standalone SC thread fences are not modelled by
  # TSAN's vector clocks (see `compiler-rt/lib/tsan/rtl/tsan_interface_atomic.cpp`,
  # `OpFence::Atomic` -> `// FIXME(dvyukov): not implemented.`). On ARM64,
  # this caused TSAN to flag the EBR pin/reclaim handshake as a race even
  # though the C11 proof goes through. SC RMWs are modelled correctly,
  # and Crossbeam uses the same encoding for the same reason.
  discard mgr.threads[idx].pinned.exchange(true, moSequentiallyConsistent)

  Pinned[MaxThreads, CC](ctx)

proc unpin*[MaxThreads: static int, CC: static PinScopeCardinality](
    p: sink Pinned[MaxThreads, CC]
): UnpinResult[MaxThreads, CC] {.transition.} =
  ## Leave critical section. Returns Neutralized if signaled.
  runnableExamples:
    import debra
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let pinned = unpinned(handle).pin()
    var res = pinned.unpin()
    match res:
      Unpinned(_):
        discard
      Neutralized(nval):
        discard nval.acknowledge()
  let ctx = EpochGuardContext[MaxThreads, CC](p)
  let mgr = ctx.handle.manager
  let idx = ctx.handle.idx

  # SC store (not Release) so the modification order on `pinned` is fully
  # ordered with the SC RMW in `pin` and the SC load in `loadEpochs`.
  # Without SC here, a reclaimer's SC load on `pinned` could read the
  # unpin's value while a subsequent re-pin RMW is in flight, breaking
  # the EBR subscription handshake.
  mgr.threads[idx].pinned.store(false, moSequentiallyConsistent)

  if mgr.threads[idx].neutralized.load(moAcquire):
    UnpinResult[MaxThreads, CC] -> Neutralized[MaxThreads, CC](ctx)
  else:
    UnpinResult[MaxThreads, CC] -> Unpinned[MaxThreads, CC](ctx)

proc acknowledge*[MaxThreads: static int, CC: static PinScopeCardinality](
    n: sink Neutralized[MaxThreads, CC]
): Unpinned[MaxThreads, CC] {.transition.} =
  ## Acknowledge neutralization. Required before re-pinning.
  ##
  ## See also: `unpin`_ (returns `Neutralized` when signaled), `pin`_.
  let ctx = EpochGuardContext[MaxThreads, CC](n)
  ctx.handle.manager.threads[ctx.handle.idx].neutralized.store(false, moRelease)
  Unpinned[MaxThreads, CC](
    EpochGuardContext[MaxThreads, CC](handle: ctx.handle, epoch: 0)
  )

proc close*[MaxThreads: static int, CC: static PinScopeCardinality](
    u: sink Unpinned[MaxThreads, CC]
): Closed[MaxThreads, CC] {.transition.} =
  ## One-way exit transition for `PinnedScope`'s destructor path.
  ##
  ## `close` is reserved for the `PinnedScope.=destroy` path; user code
  ## should rely on `PinnedScope` (or the deprecated `withPin`) to drive
  ## the lifecycle and should not call `close` directly. `close` performs
  ## no atomic operations; the slot's `pinned` and `neutralized` flags
  ## were already cleared by the preceding `unpin` (or `unpin +
  ## acknowledge`) call.
  Closed[MaxThreads, CC](EpochGuardContext[MaxThreads, CC](u))

func epoch*[MaxThreads: static int, CC: static PinScopeCardinality](
    p: Pinned[MaxThreads, CC]
): uint64 {.notATransition.} =
  ## Get the epoch this thread is pinned at.
  EpochGuardContext[MaxThreads, CC](p).epoch

func handle*[MaxThreads: static int, CC: static PinScopeCardinality](
    p: Pinned[MaxThreads, CC]
): ThreadHandle[MaxThreads, CC] {.notATransition.} =
  ## Get the thread handle.
  EpochGuardContext[MaxThreads, CC](p).handle
