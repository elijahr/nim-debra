import unittest2
import debra/atomics

import debra/types
import debra/limbo
import debra/typestates/manager
import debra/typestates/guard
import debra/typestates/retire
import debra/typestates/reclaim

type TestNodeObj = object
  value: int

proc dtor(p: pointer) {.nimcall.} =
  dealloc(p)

proc allocNode(value: int): pointer =
  let n = cast[ptr TestNodeObj](alloc0(sizeof(TestNodeObj)))
  n.value = value
  cast[pointer](n)

suite "Reclaim typestate":
  var mgr: DebraManager[4]

  setup:
    mgr = DebraManager[4]()
    discard uninitializedManager(addr mgr).initialize()

  test "reclaimStart creates ReclaimStart":
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let s = reclaimStart(handle)
    check s is ReclaimStart[4]

  test "loadEpochs computes safe epoch":
    mgr.globalEpoch.store(10'u64, moRelaxed)
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let loaded = reclaimStart(handle).loadEpochs()
    check loaded is EpochsLoaded[4]
    check loaded.safeEpoch == 10'u64

  test "checkSafe returns ReclaimReady when epoch > 1":
    mgr.globalEpoch.store(5'u64, moRelaxed)
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let check = reclaimStart(handle).loadEpochs().checkSafe()
    check check.kind == rReclaimReady

  test "tryReclaim reclaims eligible bags":
    # Setup: retire objects at epoch 1
    mgr.globalEpoch.store(1'u64, moRelaxed)
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    var ready = retireReady(p)
    for i in 0 ..< 5:
      let retired = ready.retire(allocNode(i), dtor)
      ready = retireReadyFromRetired(retired)
    discard p.unpin()

    # Advance epoch past safe threshold
    mgr.globalEpoch.store(5'u64, moRelaxed)

    # Reclaim from this handle's perspective.
    let result = reclaimStart(handle).loadEpochs().checkSafe()
    check result.kind == rReclaimReady
    let count = result.reclaimready.tryReclaim()
    check count == 5

  test "per-thread reclaim respects safe epoch":
    # `tryReclaim` reclaims only the calling thread's own retired objects.
    # Each thread is responsible for draining its own bags. This test simulates
    # three threads retiring at different epochs from the same OS thread by
    # passing distinct handles and asserts each handle's reclaim sees only its
    # own objects, gated by the global safe epoch.

    # Setup: Start at epoch 1
    mgr.globalEpoch.store(1'u64, moRelaxed)

    # Thread 0: Retire 3 objects at epoch 1
    let h0 = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p0 = unpinned(h0).pin()
    check p0.epoch == 1
    var ready0 = retireReady(p0)
    for i in 0 ..< 3:
      let retired = ready0.retire(allocNode(i), dtor)
      ready0 = retireReadyFromRetired(retired)
    discard p0.unpin()

    # Advance to epoch 2
    mgr.globalEpoch.store(2'u64, moRelaxed)

    # Thread 1: Retire 4 objects at epoch 2
    let h1 = ThreadHandle[4](idx: 1, manager: addr mgr)
    let p1 = unpinned(h1).pin()
    check p1.epoch == 2
    var ready1 = retireReady(p1)
    for i in 0 ..< 4:
      let retired = ready1.retire(allocNode(i), dtor)
      ready1 = retireReadyFromRetired(retired)
    discard p1.unpin()

    # Advance to epoch 3
    mgr.globalEpoch.store(3'u64, moRelaxed)

    # Thread 2: Retire 5 objects at epoch 3
    let h2 = ThreadHandle[4](idx: 2, manager: addr mgr)
    let p2 = unpinned(h2).pin()
    check p2.epoch == 3
    var ready2 = retireReady(p2)
    for i in 0 ..< 5:
      let retired = ready2.retire(allocNode(i), dtor)
      ready2 = retireReadyFromRetired(retired)
    discard p2.unpin()

    # Advance to epoch 5
    mgr.globalEpoch.store(5'u64, moRelaxed)

    # Pin thread 0 at epoch 5 and pin thread 1 at epoch 3 to make safeEpoch = 3.
    let p0_v2 = unpinned(h0).pin()
    check p0_v2.epoch == 5
    mgr.threads[1].epoch.store(3'u64, moRelease)
    mgr.threads[1].pinned.store(true, moRelease)

    # safeEpoch is computed from the minimum pinned epoch across all threads.
    # safeEpoch = min(5, 3) = 3, threshold = safeEpoch - 1 = 2.
    # Only bags with epoch < 2 are reclaimable in this pass.

    # Reclaim from thread 0's perspective: its bag at epoch 1 is below the
    # threshold and should be freed (3 objects).
    let r0 = reclaimStart(h0).loadEpochs().checkSafe()
    check r0.kind == rReclaimReady
    check r0.reclaimready.tryReclaim() == 3

    # Reclaim from thread 1's perspective: its bag at epoch 2 is NOT below
    # the threshold; nothing should be freed.
    let r1 = reclaimStart(h1).loadEpochs().checkSafe()
    check r1.kind == rReclaimReady
    check r1.reclaimready.tryReclaim() == 0

    # Reclaim from thread 2's perspective: its bag at epoch 3 is NOT below
    # the threshold; nothing should be freed.
    let r2 = reclaimStart(h2).loadEpochs().checkSafe()
    check r2.kind == rReclaimReady
    check r2.reclaimready.tryReclaim() == 0

    # Now unpin thread 1; safeEpoch climbs to 5 (only thread 0 still pinned).
    # Threshold becomes 4, so bags at epoch 2 and 3 become reclaimable.
    mgr.threads[1].pinned.store(false, moRelease)

    # Thread 1 reclaims its own 4 objects at epoch 2.
    let r1b = reclaimStart(h1).loadEpochs().checkSafe()
    check r1b.kind == rReclaimReady
    check r1b.reclaimready.tryReclaim() == 4

    # Thread 2 reclaims its own 5 objects at epoch 3.
    let r2b = reclaimStart(h2).loadEpochs().checkSafe()
    check r2b.kind == rReclaimReady
    check r2b.reclaimready.tryReclaim() == 5

    # Clean up remaining pinned thread
    discard p0_v2.unpin()

  test "tryReclaim ignores other threads' bags":
    # Verifies the per-thread scope explicitly: thread 0 retires, thread 1
    # reclaims; thread 0's bags are untouched.
    mgr.globalEpoch.store(1'u64, moRelaxed)

    let h0 = ThreadHandle[4](idx: 0, manager: addr mgr)
    let h1 = ThreadHandle[4](idx: 1, manager: addr mgr)

    # Thread 0 retires 3 objects at epoch 1
    let p0 = unpinned(h0).pin()
    var ready0 = retireReady(p0)
    for i in 0 ..< 3:
      let retired = ready0.retire(allocNode(i), dtor)
      ready0 = retireReadyFromRetired(retired)
    discard p0.unpin()

    # Advance well past safe threshold
    mgr.globalEpoch.store(10'u64, moRelaxed)

    # Thread 1 attempts reclaim — should reclaim NOTHING because it has no
    # retired objects of its own.
    let r1 = reclaimStart(h1).loadEpochs().checkSafe()
    check r1.kind == rReclaimReady
    check r1.reclaimready.tryReclaim() == 0

    # Thread 0's bag is still intact and still has 3 objects waiting.
    check mgr.threads[0].limboBagTail != nil
    check mgr.threads[0].limboBagTail.count == 3

    # Thread 0 reclaims its own 3 objects.
    let r0 = reclaimStart(h0).loadEpochs().checkSafe()
    check r0.kind == rReclaimReady
    check r0.reclaimready.tryReclaim() == 3
    check mgr.threads[0].limboBagTail == nil

  test "tryReclaim reclaims across multiple bags (FIFO ordering)":
    # Retire enough objects to fill 2+ bags, then reclaim. Verifies the new
    # tail-to-current FIFO list management correctly walks all eligible bags.
    mgr.globalEpoch.store(1'u64, moRelaxed)
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    var ready = retireReady(p)
    let totalObjects = LimboBagSize * 2 + 5 # 133 objects -> 3 bags
    for i in 0 ..< totalObjects:
      let retired = ready.retire(allocNode(i), dtor)
      ready = retireReadyFromRetired(retired)
    discard p.unpin()

    # Advance past safe threshold so all bags become reclaimable.
    mgr.globalEpoch.store(5'u64, moRelaxed)

    let r = reclaimStart(handle).loadEpochs().checkSafe()
    check r.kind == rReclaimReady
    check r.reclaimready.tryReclaim() == totalObjects
    # All bags freed: tail is nil, current is nil.
    check mgr.threads[0].limboBagTail == nil
    check mgr.threads[0].currentBag == nil
