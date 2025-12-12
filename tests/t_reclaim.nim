import unittest2
import atomics

import debra/types
import debra/limbo
import debra/typestates/manager
import debra/typestates/guard
import debra/typestates/retire
import debra/typestates/reclaim

var reclaimCount: int = 0
proc countingDestructor(p: pointer) {.nimcall.} =
  inc reclaimCount

suite "Reclaim typestate":
  var mgr: DebraManager[4]

  setup:
    reclaimCount = 0
    mgr = DebraManager[4]()
    discard uninitializedManager(addr mgr).initialize()

  test "reclaimStart creates ReclaimStart":
    let s = reclaimStart(addr mgr)
    check s is ReclaimStart[4]

  test "loadEpochs computes safe epoch":
    mgr.globalEpoch.store(10'u64, moRelaxed)
    let loaded = reclaimStart(addr mgr).loadEpochs()
    check loaded is EpochsLoaded[4]
    check loaded.safeEpoch == 10'u64

  test "checkSafe returns ReclaimReady when epoch > 1":
    mgr.globalEpoch.store(5'u64, moRelaxed)
    let check = reclaimStart(addr mgr).loadEpochs().checkSafe()
    check check.kind == rReclaimReady

  test "tryReclaim reclaims eligible bags":
    # Setup: retire objects at epoch 1
    mgr.globalEpoch.store(1'u64, moRelaxed)
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    var ready = retireReady(p)
    for i in 0..<5:
      let retired = ready.retire(nil, countingDestructor)
      ready = retireReadyFromRetired(retired)
    discard p.unpin()

    # Advance epoch past safe threshold
    mgr.globalEpoch.store(5'u64, moRelaxed)

    # Reclaim
    let result = reclaimStart(addr mgr).loadEpochs().checkSafe()
    check result.kind == rReclaimReady
    let count = result.reclaimready.tryReclaim()
    check count == 5
    check reclaimCount == 5

  test "multi-thread reclaim with different pinned epochs":
    # This test verifies that reclamation correctly identifies the safe epoch
    # based on the minimum pinned epoch across all threads, and only reclaims
    # objects from epochs below that safe epoch.

    # Setup: Start at epoch 1
    mgr.globalEpoch.store(1'u64, moRelaxed)

    # Thread 0: Retire 3 objects at epoch 1
    let h0 = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p0 = unpinned(h0).pin()
    check p0.epoch == 1
    var ready0 = retireReady(p0)
    for i in 0..<3:
      let retired = ready0.retire(nil, countingDestructor)
      ready0 = retireReadyFromRetired(retired)
    discard p0.unpin()

    # Advance to epoch 2
    mgr.globalEpoch.store(2'u64, moRelaxed)

    # Thread 1: Retire 4 objects at epoch 2
    let h1 = ThreadHandle[4](idx: 1, manager: addr mgr)
    let p1 = unpinned(h1).pin()
    check p1.epoch == 2
    var ready1 = retireReady(p1)
    for i in 0..<4:
      let retired = ready1.retire(nil, countingDestructor)
      ready1 = retireReadyFromRetired(retired)
    discard p1.unpin()

    # Advance to epoch 3
    mgr.globalEpoch.store(3'u64, moRelaxed)

    # Thread 2: Retire 5 objects at epoch 3
    let h2 = ThreadHandle[4](idx: 2, manager: addr mgr)
    let p2 = unpinned(h2).pin()
    check p2.epoch == 3
    var ready2 = retireReady(p2)
    for i in 0..<5:
      let retired = ready2.retire(nil, countingDestructor)
      ready2 = retireReadyFromRetired(retired)
    discard p2.unpin()

    # Advance to epoch 5
    mgr.globalEpoch.store(5'u64, moRelaxed)

    # Now pin threads at different epochs to create interesting reclaim scenario:
    # - Thread 0: pin at epoch 5 (current)
    # - Thread 1: pin at epoch 3 (older) - this will be the minimum
    # - Thread 2: not pinned
    # - Thread 3: not pinned

    let p0_v2 = unpinned(h0).pin()
    check p0_v2.epoch == 5

    # Manually set thread 1's pinned state at epoch 3 to simulate
    # a thread that pinned earlier and is still in critical section
    mgr.threads[1].epoch.store(3'u64, moRelease)
    mgr.threads[1].pinned.store(true, moRelease)

    # Verify loadEpochs computes correct safe epoch
    let loaded = reclaimStart(addr mgr).loadEpochs()
    check loaded.safeEpoch == 3  # Minimum of pinned threads: min(5, 3) = 3

    # Check reclaim is ready (safeEpoch > 1)
    let result = loaded.checkSafe()
    check result.kind == rReclaimReady

    # Reclaim - with safeEpoch = 3, the reclaim threshold is (3 - 1) = 2
    # This means bags with epoch < 2 are reclaimed (i.e., only epoch 1)
    # This conservative approach ensures safety:
    # - epoch 1 objects (3 items) should be reclaimed
    # - epoch 2 objects (4 items) should NOT be reclaimed yet (not safe)
    # - epoch 3 objects (5 items) should NOT be reclaimed (not safe)
    let count = result.reclaimready.tryReclaim()
    check count == 3  # Only the 3 from epoch 1
    check reclaimCount == 3

    # Unpin thread 1 (which was at epoch 3)
    mgr.threads[1].pinned.store(false, moRelease)

    # Now minimum pinned epoch is just thread 0 at epoch 5
    # Try reclaim again with only thread 0 pinned at epoch 5
    reclaimCount = 0
    let loaded2 = reclaimStart(addr mgr).loadEpochs()
    check loaded2.safeEpoch == 5  # Only thread 0 pinned at epoch 5

    let result2 = loaded2.checkSafe()
    check result2.kind == rReclaimReady
    # With safeEpoch = 5, threshold is 4, so bags with epoch < 4 are reclaimable
    # This includes epoch 2 (4 objects) and epoch 3 (5 objects)
    let count2 = result2.reclaimready.tryReclaim()
    check count2 == 9  # 4 from epoch 2 + 5 from epoch 3
    check reclaimCount == 9

    # Clean up remaining pinned thread
    discard p0_v2.unpin()
