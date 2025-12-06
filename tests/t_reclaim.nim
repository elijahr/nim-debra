# tests/t_reclaim.nim

import unittest2
import atomics

import debra

suite "Reclamation Typestate":
  var manager: DebraManager[4]

  setup:
    manager = initDebraManager[4]()
    setGlobalManager(addr manager)

  test "checkSafe returns Ready when epoch > 1":
    manager.globalEpoch.store(5'u64, moRelaxed)
    var op = reclaimStart[4]()
    let loaded = op.loadEpochs(manager)
    let checkResult = loaded.checkSafe()
    check checkResult.kind == cReclaimReady

  test "checkSafe returns Blocked when epoch <= 1":
    manager.globalEpoch.store(1'u64, moRelaxed)
    var op = reclaimStart[4]()
    let loaded = op.loadEpochs(manager)
    let checkResult = loaded.checkSafe()
    check checkResult.kind == cReclaimBlocked

  test "safeEpoch accounts for pinned threads":
    manager.globalEpoch.store(10'u64, moRelaxed)
    # Pin a thread at epoch 5
    manager.threads[0].pinned.store(true, moRelaxed)
    manager.threads[0].epoch.store(5'u64, moRelaxed)

    var op = reclaimStart[4]()
    let loaded = op.loadEpochs(manager)
    check loaded.safeEpoch == 5'u64

  test "canReclaim returns true for old epochs":
    manager.globalEpoch.store(10'u64, moRelaxed)
    var op = reclaimStart[4]()
    let loaded = op.loadEpochs(manager)
    let checkResult = loaded.checkSafe()
    check checkResult.kind == cReclaimReady
    let ready = checkResult.reclaimready
    check ready.canReclaim(1'u64) == true
    check ready.canReclaim(8'u64) == true
    check ready.canReclaim(9'u64) == false
