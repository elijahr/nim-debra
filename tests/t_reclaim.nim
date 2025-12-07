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
