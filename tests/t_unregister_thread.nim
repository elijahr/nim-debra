# tests/t_unregister_thread.nim
##
## RED test suite for `unregisterThread` (Task B3 of the v0.9.0 static
## thread-affinity work).
##
## Locked operator-decided signature (2026-05-30):
##
##   proc unregisterThread*[
##       MaxThreads: static int,
##       CC: static PinScopeCardinality = ccSingle,
##   ](
##     manager: var DebraManager[MaxThreads, CC],
##     handle: ThreadHandle[MaxThreads, CC],
##   ) {.raises: [].}
##
## Baseline (recorded in Task B0):
## - Slot ownership: bit in `manager.activeThreadMask` (typestates/registration.nim,
##   `register` body, CAS with moRelease success / moAcquire failure).
## - Companion store: `threads[i].threadId` (signal-delivery hint; free
##   sentinel is `InvalidThreadId`, set by `initDebraManager` in types.nim).
## - `ThreadHandle` carries no epoch/generation; stale-handle reuse aliasing
##   is documented misuse and is NOT a B3 contract (B4 may revisit).
## - Thread-locals set by `register` (typestates/registration.nim ~line 98):
##   `threadLocalIdx`, `threadLocalRegistered`, `threadLocalManager`.
##
## Out-of-scope for B3 RED (will be covered later in the track):
## - Concurrent stress test (Task B4.5).
## - Stale-handle aliasing: handle survives, slot is reclaimed by another
##   thread, then the stale handle is passed to `unregisterThread`. B4 will
##   decide whether the runtime detects this (probably not, given no
##   generation counter); this RED suite does not pin a contract here.

import unittest2

import debra
import debra/atomics
import debra/signal
import debra/thread_id
import debra/types
import debra/typestates/cardinality

suite "unregisterThread — runtime API on DebraManager (ccSingle)":
  test "round-trip clears mask bit AND threadId slot":
    var mgr = initDebraManager[4]()
    setGlobalManager(addr mgr)
    let h = registerThread(mgr)
    # Pre-condition: slot is claimed; threadId is the calling thread.
    check mgr.activeThreadMask.load(moAcquire) == (1'u64 shl h.idx)
    check mgr.threads[h.idx].threadId.load(moAcquire) == currentThreadId()

    unregisterThread(mgr, h)

    # Post-condition: mask bit cleared, threadId reset to free sentinel.
    check mgr.activeThreadMask.load(moAcquire) == 0'u64
    check mgr.threads[h.idx].threadId.load(moAcquire) == InvalidThreadId

  test "freed slot is reusable by a subsequent register on the same thread":
    var mgr = initDebraManager[4]()
    setGlobalManager(addr mgr)
    let h1 = registerThread(mgr)
    unregisterThread(mgr, h1)
    # A second register on the same thread must succeed and reclaim the
    # first free slot (index 0 in the scan order).
    let h2 = registerThread(mgr)
    check h2.idx == h1.idx
    check h2.manager == addr mgr
    check mgr.activeThreadMask.load(moAcquire) == (1'u64 shl h2.idx)

  test "idempotent: double-deregister does not raise and leaves state clear":
    ## Operator-locked contract per `most_correct_least_deferred`:
    ## double-deregister is a no-op. Documented here; if the B4
    ## implementer chooses an alternative shape (assert / error), surface
    ## to the operator before changing this expectation.
    var mgr = initDebraManager[4]()
    setGlobalManager(addr mgr)
    let h = registerThread(mgr)
    unregisterThread(mgr, h)
    unregisterThread(mgr, h) # second call must be a no-op
    check mgr.activeThreadMask.load(moAcquire) == 0'u64
    check mgr.threads[h.idx].threadId.load(moAcquire) == InvalidThreadId

  test "thread-locals (idx, registered flag, manager pointer) are cleared":
    var mgr = initDebraManager[4]()
    setGlobalManager(addr mgr)
    let h = registerThread(mgr)
    # Pre-condition: register populated all three threadvars.
    check threadLocalRegistered == true
    check threadLocalIdx == h.idx
    check threadLocalManager == cast[pointer](addr mgr)

    unregisterThread(mgr, h)

    # Post-condition: all three threadvars cleared. `threadLocalIdx`
    # must be reset to 0 (the zero value); the registered flag is the
    # authoritative bit per signal.nim:104-108, so it MUST be false.
    check threadLocalRegistered == false
    check threadLocalIdx == 0
    check threadLocalManager == nil

  test "compile-time contract: unregisterThread is {.raises: [].}":
    ## A `compiles()` block asserting that `unregisterThread` typechecks
    ## inside a `{.raises: [].}` proc. If B4 introduces any raising
    ## effect, this test fails to compile.
    proc raisesNothing(
        mgr: var DebraManager[4, ccSingle], h: ThreadHandle[4, ccSingle]
    ) {.raises: [].} =
      unregisterThread(mgr, h)

    check compiles(raisesNothing)

suite "unregisterThread — CC-generic (ccMulti)":
  test "round-trip works on ccMulti manager":
    var mgr = initDebraManager[4, ccMulti]()
    setGlobalManager(addr mgr)
    let h = registerThread(mgr)
    check mgr.activeThreadMask.load(moAcquire) == (1'u64 shl h.idx)

    unregisterThread(mgr, h)

    check mgr.activeThreadMask.load(moAcquire) == 0'u64
    check mgr.threads[h.idx].threadId.load(moAcquire) == InvalidThreadId

  test "compile-time contract: {.raises: [].} on ccMulti instantiation":
    proc raisesNothingMulti(
        mgr: var DebraManager[4, ccMulti], h: ThreadHandle[4, ccMulti]
    ) {.raises: [].} =
      unregisterThread(mgr, h)

    check compiles(raisesNothingMulti)
