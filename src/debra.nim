## nim-debra: DEBRA+ Safe Memory Reclamation
##
## This library provides typestate-enforced epoch-based reclamation
## with signal-based neutralization for lock-free data structures.

when not compileOption("threads"):
  {.error: "nim-debra requires --threads:on".}

import ./debra/atomics
import ./debra/types
import ./debra/signal
import ./debra/limbo
import ./debra/thread_id
import ./debra/typestates/cardinality
import ./debra/typestates/signal_handler
import ./debra/typestates/manager
import ./debra/typestates/registration
import ./debra/typestates/guard
import ./debra/typestates/retire
import ./debra/typestates/pinned_scope
import ./debra/typestates/reclaim
import ./debra/typestates/neutralize
import ./debra/typestates/advance
import ./debra/typestates/slot
import ./debra/refptr
import ./debra/convenience

export types
export signal.setGlobalManager, signal.installSignalHandler
export limbo
export thread_id
export cardinality
export signal_handler
export manager
export registration
export guard
export retire
export pinned_scope
export reclaim
export neutralize
export advance
export slot
export refptr
export convenience

proc registerThread*[MaxThreads: static int, CC: static PinScopeCardinality](
    manager: var DebraManager[MaxThreads, CC]
): ThreadHandle[MaxThreads, CC] {.raises: [DebraRegistrationError].} =
  ## Register current thread with the DEBRA manager.
  ##
  ## Must be called once per thread before any epoch operations.
  ## Raises DebraRegistrationError if max threads already registered.
  ##
  ## The `CC` parameter binds via the `manager` argument, so callers
  ## that pass `DebraManager[N]` (which defaults `CC = ccSingle`)
  ## receive `ThreadHandle[N, ccSingle]` unchanged from 0.7.x.
  installSignalHandler()

  let u = unregistered(addr manager)
  var regResult = u.register()
  match regResult:
    Registered(reg):
      return reg.getHandle()
    RegistrationFull(_):
      raise newException(
        DebraRegistrationError,
        "Maximum threads (" & $MaxThreads & ") already registered",
      )

proc unregisterThread*[
    MaxThreads: static int, CC: static PinScopeCardinality = ccSingle
](
    manager: var DebraManager[MaxThreads, CC], handle: ThreadHandle[MaxThreads, CC]
) {.raises: [].} =
  ## Unregister the current thread from the DEBRA manager, releasing the
  ## slot it claimed via `registerThread`. Idempotent under no concurrent
  ## re-claim: a second call with the same `handle` is a no-op IF no other
  ## thread has reclaimed the slot in between. If the slot has been
  ## concurrently re-claimed, the runtime `doAssert` below detects
  ## stale-handle aliasing and raises an `AssertionDefect`.
  ##
  ## **Caller obligations** (documented misuse):
  ##
  ## - **Thread-affine**: must be called from the same OS thread that
  ##   called `registerThread` to obtain `handle`. The per-thread bookkeeping
  ##   (`threadLocalIdx`, `threadLocalRegistered`, `threadLocalManager`) is
  ##   per-thread, so a cross-thread call leaves the owning thread's
  ##   threadvars stale and will misroute future signal delivery.
  ## - **No in-flight pin**: any `PinnedScope` opened against `handle` must
  ##   have been closed before this call. `unregisterThread` does not
  ##   un-pin; releasing a slot with an active pin is a use-after-free.
  ## - **Stale-handle aliasing is detected at runtime (Gemini round-2 HIGH)**:
  ##   a `doAssert` after the idempotency early-return checks that the
  ##   per-thread `threadLocalRegistered` / `threadLocalIdx` /
  ##   `threadLocalManager` match the `handle` + `manager` arguments.
  ##   Cross-thread call or stale-handle reuse on a live (re-claimed) slot
  ##   raises `AssertionDefect`. This is a runtime defense; the contract
  ##   remains "don't do this" and the per-thread bookkeeping is the
  ##   source of truth.
  ##
  ## **Clear order** (matters for concurrent signal delivery):
  ##
  ## 1. Reset `threads[idx].threadId` to `InvalidThreadId` (release) — closes
  ##    the signal-delivery hint before the mask bit advertises the slot as
  ##    free.
  ## 2. Clear the mask bit via CAS-with-retry, mirroring `register`'s
  ##    claim-side pattern.
  ## 3. Clear the three thread-locals last.
  ##
  ## The `CC` parameter binds via the `manager` argument; callers that pass
  ## `DebraManager[N]` (CC default `ccSingle`) keep the 0.7.x call shape,
  ## while `DebraManager[N, ccMulti]` is also accepted.

  # Bounds check on a stale/corrupt handle. Out-of-range idx returns
  # early (idempotent-style) rather than indexing garbage.
  if handle.idx < 0 or handle.idx >= MaxThreads:
    return

  let bit = 1'u64 shl handle.idx

  # Idempotency check: if the mask bit is already clear, this is a
  # double-unregister or a stale handle to a slot already freed; either
  # way, no-op.
  if (manager.activeThreadMask.load(moAcquire) and bit) == 0'u64:
    return

  # Defensive runtime enforcement (Gemini round-2 PR #13 HIGH): the
  # docstring contracts (thread-affine, no stale handle on a live slot)
  # are caller obligations, but violating them silently corrupts state
  # (cross-thread unregister; signal misroute). `unregisterThread` is
  # off the hot path, so the cost is negligible. Mirrors the defensive
  # style of `unbindClient` and `withPin`'s nested-pin check.
  doAssert threadLocalRegistered and threadLocalIdx == handle.idx and
    threadLocalManager == cast[pointer](addr manager),
    "unregisterThread: thread-affinity violation or stale handle on a live slot"

  # Step 1: clear the signal-delivery hint BEFORE releasing the mask bit.
  # Inverse order would expose a window where the mask says "free" but the
  # threadId still points at the (now-departing) thread.
  #
  # KNOWN_GAP (Windows): the slot's `ThreadId` carries a duplicated thread
  # handle allocated by `currentThreadId()` at `registerThread` time.
  # We do NOT close it here. An earlier attempt (898c160) used
  # `exchange + closeThreadId` to recover and release the outgoing
  # handle, but that introduced a use-after-close race window: a
  # concurrent `scanAndSignal` could have already loaded the handle into
  # a local variable before this `unregisterThread` ran, and would then
  # call `SuspendThread` on the freed handle. Bounding the leak safely
  # requires either (a) deferring the close until no scanner can hold a
  # reference (per-manager pending-close queue drained inside scan epoch)
  # or (b) reclaiming on next slot reuse / manager `=destroy`. v0.11.0
  # will pick one; v0.10.0 keeps the previously-documented leak (~3200
  # handles per stress run, bounded for the test surface but unbounded
  # for production callers with heavy thread churn) rather than ship a
  # crash regression on Windows. See PR #14 cycle-22 for the CI trace.
  manager.threads[handle.idx].threadId.store(InvalidThreadId, moRelease)

  # Step 2: clear the mask bit via CAS-with-retry, mirroring the
  # claim-side pattern in `register` (registration.nim:82-90).
  var expected = manager.activeThreadMask.load(moAcquire)
  while (expected and bit) != 0'u64:
    let desired = expected and not bit
    if manager.activeThreadMask.compareExchangeWeak(
      expected, desired, moAcquireRelease, moAcquire
    ):
      break
    # CAS failed; `expected` is updated. If another writer cleared the
    # bit in the meantime (shouldn't happen under thread-affine usage but
    # is defensible), the loop guard exits.

  # Step 3: clear thread-locals last. Only meaningful on the owning thread
  # (per the thread-affine contract above); on a wrong thread these clears
  # would scribble the caller's threadvars instead of the owner's, which
  # is the caller's bug, not ours.
  threadLocalIdx = 0
  threadLocalRegistered = false
  threadLocalManager = nil

proc neutralizeStalled*[MaxThreads: static int](
    manager: var DebraManager[MaxThreads], epochsBeforeNeutralize: uint64 = 2
): int =
  ## Signal all stalled threads. Returns number of signals sent.
  let op = scanStart(addr manager)
  let scanning = op.loadEpoch(epochsBeforeNeutralize)
  let complete = scanning.scanAndSignal()
  complete.extractSignalCount()

proc advance*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]
) {.inline.} =
  ## Advance the global epoch.
  ##
  ## The `CC` parameter binds via the `manager` argument; callers that
  ## pass `DebraManager[N]` (CC default `ccSingle`) keep the 0.7.x call
  ## shape, while `DebraManager[N, ccMulti]` is also accepted.
  discard manager.globalEpoch.fetchAdd(1'u64, moRelease)

proc currentEpoch*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]
): uint64 {.inline.} =
  ## Get current global epoch.
  ##
  ## The `CC` parameter binds via the `manager` argument; callers that
  ## pass `DebraManager[N]` (CC default `ccSingle`) keep the 0.7.x call
  ## shape, while `DebraManager[N, ccMulti]` is also accepted.
  manager.globalEpoch.load(moAcquire)

proc bindClient*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]
) {.inline.} =
  ## Register a client (e.g. a lock-free data structure) as bound to
  ## this manager. Increments `boundClients` by 1.
  ##
  ## Lock-free libraries built on nim-debra should call `bindClient` in
  ## their constructor and `unbindClient` in their destructor. The
  ## manager's destructor asserts the count is zero, so a non-zero
  ## count at teardown means a client outlived its manager: the client
  ## would continue calling into freed manager state.
  ##
  ## The `CC` parameter binds via the `manager` argument; callers that
  ## pass `DebraManager[N]` (CC default `ccSingle`) keep the 0.7.x call
  ## shape, while `DebraManager[N, ccMulti]` is also accepted.
  discard manager.boundClients.fetchAdd(1, moAcquireRelease)

proc unbindClient*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]
) {.inline.} =
  ## Unregister a client previously bound via `bindClient`. Decrements
  ## `boundClients` by 1. See `bindClient` for usage.
  ##
  ## Asserts the previous count was positive: an underflow indicates an
  ## unbalanced unbind (e.g. double-destroy of a client) and is caught
  ## here with a precise stack trace, rather than later as a non-zero
  ## value seen by the manager destructor.
  ##
  ## The `CC` parameter binds via the `manager` argument; callers that
  ## pass `DebraManager[N]` (CC default `ccSingle`) keep the 0.7.x call
  ## shape, while `DebraManager[N, ccMulti]` is also accepted.
  let prev = manager.boundClients.fetchSub(1, moAcquireRelease)
  doAssert prev > 0,
    "unbindClient: boundClients underflow (was " & $prev &
      ", expected > 0); unbalanced bindClient/unbindClient"

proc clientCount*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    manager: var DebraManager[MaxThreads, CC]
): int {.inline.} =
  ## Number of clients currently bound to this manager. Relaxed load,
  ## suitable for inspection and tests; not synchronized against
  ## concurrent `bindClient` / `unbindClient`.
  ##
  ## The `CC` parameter binds via the `manager` argument; callers that
  ## pass `DebraManager[N]` (CC default `ccSingle`) keep the 0.7.x call
  ## shape, while `DebraManager[N, ccMulti]` is also accepted.
  manager.boundClients.load(moRelaxed)
