## High-level convenience API for common DEBRA patterns.
##
## These procs compose the low-level typestate API for frequent use cases.
## For fine-grained control or batching, use the typestate API directly.
##
## ## Pitfalls
##
## * `withPin` does not allow re-pinning the same handle inside its body.
##   A debug `assert` catches direct nesting; under `-d:release` the assert
##   is a no-op and the second `pin` will corrupt the pinned-flag on the
##   thread's slot. Different handles (multi-manager) are independent.
## * Do not invoke explicit typestate transitions
##   (`unpinned`/`pin`/`unpin`/`acknowledge`) inside a `withPin` body. The
##   `try`/`finally` already manages the lifecycle; manual transitions on the
##   same handle desync the slot's `pinned` flag.
## * `it` injected by `withPin` is a `var RetireReady[MT]`; it is only valid
##   inside the body. Items retired via `it.retire(...)` and `it.retireBatch(...)`
##   are added to the thread's limbo bag at the pinned epoch and are not
##   reclaimed until a later reclamation pass observes a safe epoch.
## * `reclaimNow` returns 0 when no epoch is safe to reclaim yet. That is
##   normal at startup or when no thread has advanced the epoch since the
##   last retire. It is not an error; reclamation is best-effort.
## * `retireBatch` retires from the supplied `openArray` synchronously. The
##   array contents are copied into the limbo bag during the call, so the
##   caller's array does not need to outlive the reclamation pass.
##
## ## See also
##
## * `debra/typestates/guard`_ - explicit `pin` / `unpin` typestate transitions.
## * `debra/typestates/retire`_ - typestate `retire` (sink form).
## * `debra/typestates/reclaim`_ - typestate `reclaimStart` / `tryReclaim`.

import ./atomics
import ./types
import ./limbo
import ./managed
import ./typestates/guard
import ./typestates/retire
import ./typestates/reclaim

# ---------------------------------------------------------------------------
# Batched retire/reclaim API (see docs/design/2026-04-25-batched-retire-reclaim.md)
# ---------------------------------------------------------------------------

proc retire*[MT: static int](
    pin: var RetireReady[MT], p: pointer, destructor: Destructor
) =
  ## Retire `p` inside an existing pinned epoch held by `pin`.
  ##
  ## Wraps the sink-form `retire` from typestates/retire.nim so the caller
  ## can chain `it.retire(...)` repeatedly inside a `withPin` body without
  ## manually rebuilding `RetireReady` from `Retired`.
  runnableExamples:
    import debra
    proc dtor(p: pointer) {.nimcall.} = dealloc(p)
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    withPin(handle):
      let p = alloc0(8)
      it.retire(p, dtor)
  let retired = retire(move(pin), p, destructor)
  pin = retireReadyFromRetired(retired)

proc retire*[T: ref, MT: static int](
    pin: var RetireReady[MT], obj: Managed[T]
) =
  ## Retire a `Managed[ref T]` inside an existing pinned epoch held by `pin`.
  ##
  ## Prefer the pointer-form overload (`retire(pin, p, destructor)`) plus
  ## `retain`/`releaseDestructor` from `debra/refptr` for atomic node
  ## pointers. `Atomic[Managed[ref T]]` falls back to spinlocks under
  ## arc/orc, defeating lock-free guarantees.
  runnableExamples("-d:allowSpinlockManagedRef"):
    import debra
    type Node = ref object
      value: int
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    withPin(handle):
      let n = managed Node(value: 7)
      it.retire(n)
  let retired = retire(move(pin), obj)
  pin = retireReadyFromRetired(retired)

proc retireBatch*[MT: static int](
    pin: var RetireReady[MT], items: openArray[(pointer, Destructor)]
) =
  ## Retire each `(p, dtor)` in `items` inside an existing pinned epoch.
  ##
  ## Must be called from within `withPin` body (or any other holder of a
  ## `var RetireReady[MT]`). No pinning, no reclamation. Avoids one
  ## pin/unpin per object when freeing chains.
  runnableExamples:
    import debra
    proc dtor(p: pointer) {.nimcall.} = dealloc(p)
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let a = alloc0(8)
    let b = alloc0(8)
    withPin(handle):
      it.retireBatch([(a, dtor), (b, dtor)])
  for item in items:
    pin.retire(item[0], item[1])

template withPin*[MT: static int](
    th: ThreadHandle[MT], body: untyped
) =
  ## Pin the calling thread, run `body`, unpin on exit (including raises).
  ##
  ## Injects `it` as a `var RetireReady[MT]` (matches the Nim convention
  ## used by `filterIt`/`mapIt`). Body may call `it.retire(p, dtor)` zero
  ## or more times. Using `it` avoids collisions with the exported `pin`
  ## proc from `debra/typestates/guard`.
  ##
  ## Under debug builds, asserts the thread is not already pinned on the
  ## given handle. Under `-d:release`/`-d:danger` the assertion is a no-op.
  ## Different-handle nesting (multi-manager) is independent and legal.
  ##
  ## See also: `debra/typestates/guard.pin`_ (explicit transition), `retire`_,
  ## `retireBatch`_.
  runnableExamples:
    import debra
    proc dtor(p: pointer) {.nimcall.} = dealloc(p)
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    withPin(handle):
      let p = alloc0(8)
      it.retire(p, dtor)
  block:
    let h = th
    assert not h.manager.threads[h.idx].pinned.load(moAcquire),
      "withPin: thread is already pinned (handle slot " & $h.idx &
      "). Nested pinning is forbidden."
    let pinnedGuard = unpinned(h).pin()
    var it {.inject.} = retireReady(pinnedGuard)
    try:
      body
    finally:
      let ctx = RetireContext[MT](it)
      let p = Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
      discard p.unpin()

template withPin*[MT: static int](
    th: ThreadHandle[MT], name, body: untyped
) =
  ## `withPin` variant that injects a caller-supplied identifier `name`
  ## (instead of the default `it`). Use to disambiguate nested handles
  ## across multiple managers.
  runnableExamples:
    import debra
    proc dtor(p: pointer) {.nimcall.} = dealloc(p)
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    withPin(handle, slot):
      let p = alloc0(8)
      slot.retire(p, dtor)
  block:
    let h = th
    assert not h.manager.threads[h.idx].pinned.load(moAcquire),
      "withPin: thread is already pinned (handle slot " & $h.idx &
      "). Nested pinning is forbidden."
    let pinnedGuard = unpinned(h).pin()
    var name {.inject.} = retireReady(pinnedGuard)
    try:
      body
    finally:
      let ctx = RetireContext[MT](name)
      let p = Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
      discard p.unpin()

proc advanceEvery*[MT: static int](
    handle: ThreadHandle[MT], n: int
): bool {.discardable.} =
  ## Increment a per-handle counter; advance the global epoch once every
  ## `n` calls. Returns `true` on the calls that actually advanced.
  ##
  ## Cadence helper for the most common epoch advancement pattern: call this
  ## from a hot path (e.g. after each retire, or once per pop) without paying
  ## an atomic store on every invocation. Most calls are a single non-atomic
  ## increment plus a branch; only every Nth call performs the atomic
  ## `fetchAdd` on the global epoch.
  ##
  ## The counter lives on the handle's per-thread slot and is owned by the
  ## registered thread. No synchronization is required; different handles
  ## have independent counters.
  ##
  ## `n` must be `>= 1`. `n == 1` advances every call (equivalent to calling
  ## `manager.advance()` directly). Larger `n` reduces atomic-store traffic
  ## at the cost of letting the limbo bag fill more between advances.
  ##
  ## Typical cadences:
  ##
  ## * `n = 1`: advance every call. Simplest; highest throughput cost.
  ## * `n = 32` to `n = 128`: good general default for queue hot paths.
  ## * `n = 1024+`: very low-overhead, but limbo bag may grow noticeably.
  ##
  ## See also: `advance`_, `reclaimNow`_, the
  ## `epoch advancement guide<../guide/epoch-advancement.md>`_.
  runnableExamples:
    import debra
    proc dtor(p: pointer) {.nimcall.} = dealloc(p)
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    # Hot loop: retire and amortize the global-epoch atomic store.
    for i in 0 ..< 100:
      withPin(handle):
        it.retire(alloc0(8), dtor)
      handle.advanceEvery(32)
    discard reclaimNow(manager)
  assert n >= 1, "advanceEvery: n must be >= 1"
  let state = addr handle.manager.threads[handle.idx]
  state.advanceCounter += 1'u64
  if state.advanceCounter mod uint64(n) == 0'u64:
    discard handle.manager.globalEpoch.fetchAdd(1'u64, moRelease)
    return true
  return false

proc reclaimNow*[MT: static int](handle: ThreadHandle[MT]): int =
  ## Run one reclamation pass over the calling thread's own retired objects.
  ## Returns the number of objects reclaimed, or 0 if no epoch is currently
  ## safe to reclaim.
  ##
  ## Pinning is not required: reclamation only inspects per-thread epochs.
  ## Each thread reclaims only its own bags; cross-thread reclamation is not
  ## supported because the bag list is mutated by the owning thread (via
  ## `retire`) without synchronization.
  ##
  ## See also: `debra/typestates/reclaim.tryReclaim`_, `advance`_.
  runnableExamples:
    import debra
    proc dtor(p: pointer) {.nimcall.} = dealloc(p)
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    # Brand-new manager: no retired objects, returns 0 (not an error).
    doAssert reclaimNow(handle) == 0
    # Retire something, advance the epoch a few times, then reclaim.
    withPin(handle):
      it.retire(alloc0(8), dtor)
    manager.advance()
    manager.advance()
    discard reclaimNow(handle)
  let op = reclaimStart(handle).loadEpochs().checkSafe()
  if op.kind == rReclaimReady:
    op.reclaimready.tryReclaim()
  else:
    0

proc reclaimNow*[MT: static int](manager: var DebraManager[MT]): int =
  ## Legacy wrapper: infers the calling thread's slot from `threadLocalIdx`
  ## (set by `registerThread`). Prefer `reclaimNow(handle)` for clarity and
  ## for safety from unregistered threads.
  ##
  ## See also: `debra/typestates/reclaim.tryReclaim`_, `advance`_.
  let op = reclaimStart(addr manager).loadEpochs().checkSafe()
  if op.kind == rReclaimReady:
    op.reclaimready.tryReclaim()
  else:
    0

proc retireAndReclaim*[MT: static int](
    handle: ThreadHandle[MT], p: pointer, destructor: Destructor, eager: bool = true
) =
  ## Retire a pointer and optionally attempt immediate reclamation.
  ##
  ## This convenience wrapper:
  ## 1. Pins the current thread
  ## 2. Retires the pointer with the given destructor
  ## 3. Unpins the thread
  ## 4. If eager=true (default), attempts to reclaim retired objects
  ##
  ## For batching multiple retirements before reclaiming, use the
  ## low-level typestate API directly or call with eager=false.
  runnableExamples:
    import debra
    proc destroyNode(p: pointer) {.nimcall.} = dealloc(p)
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let node = alloc0(16)
    retireAndReclaim(handle, node, destroyNode)
    # Or skip the eager pass when batching many retires:
    let other = alloc0(16)
    retireAndReclaim(handle, other, destroyNode, eager = false)
  # Pin, retire, unpin
  let pinned = unpinned(handle).pin()
  let ready = retireReady(pinned)
  let retired = ready.retire(p, destructor)

  # Convert Retired back to Pinned for unpinning
  let ctx = RetireContext[MT](retired)
  let pinnedAgain =
    Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
  discard pinnedAgain.unpin()

  # Optional eager reclamation (per-thread, scoped to this handle's slot).
  if eager:
    let reclaim = reclaimStart(handle).loadEpochs().checkSafe()
    if reclaim.kind == rReclaimReady:
      discard reclaim.reclaimready.tryReclaim()

proc retireAndReclaim*[T: ref, MT: static int](
    handle: ThreadHandle[MT], obj: Managed[T], eager: bool = true
) =
  ## Retire a Managed[ref T] and optionally attempt immediate reclamation.
  ##
  ## WARNING: Managed[ref T] uses spinlock-based atomics on arc/orc memory
  ## managers, defeating lock-free guarantees. Prefer pointer-based
  ## retire(ptr, destructor) for lock-free code.
  ##
  ## This convenience wrapper:
  ## 1. Pins the current thread
  ## 2. Retires the managed object
  ## 3. Unpins the thread
  ## 4. If eager=true (default), attempts to reclaim retired objects
  runnableExamples("-d:allowSpinlockManagedRef"):
    import debra
    type Node = ref object
      value: int
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let node = managed Node(value: 42)
    retireAndReclaim(handle, node)
  # Pin, retire, unpin
  let pinned = unpinned(handle).pin()
  let ready = retireReady(pinned)
  let retired = ready.retire(obj)

  # Convert Retired back to Pinned for unpinning
  let ctx = RetireContext[MT](retired)
  let pinnedAgain =
    Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
  discard pinnedAgain.unpin()

  # Optional eager reclamation (per-thread, scoped to this handle's slot).
  if eager:
    let reclaim = reclaimStart(handle).loadEpochs().checkSafe()
    if reclaim.kind == rReclaimReady:
      discard reclaim.reclaimready.tryReclaim()
