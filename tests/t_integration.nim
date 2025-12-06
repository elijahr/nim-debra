# tests/t_integration.nim

import unittest2
import atomics
import os

import debra

suite "Integration":
  test "full workflow: register, pin, unpin, reclaim":
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)

    # Register thread
    let handle = registerThread(manager)
    check handle.idx >= 0

    # Pin
    let pinned = handle.pin()
    check manager.threads[handle.idx].pinned.load(moAcquire) == true

    # Advance epoch while pinned
    manager.advance()
    manager.advance()

    # Unpin
    let unpinResult = pinned.unpin()
    check unpinResult.kind == uEpochUnpinned

    # Now reclamation should be possible
    var op = reclaimStart[4]()
    let loaded = op.loadEpochs(manager)
    let checkResult = loaded.checkSafe()
    check checkResult.kind == cReclaimReady

  test "neutralization acknowledgment cycle":
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)

    let handle = registerThread(manager)

    # Pin
    let pinned = handle.pin()

    # Simulate being neutralized
    manager.threads[handle.idx].neutralized.store(true, moRelease)

    # Unpin should detect neutralization
    let unpinResult = pinned.unpin()
    check unpinResult.kind == uEpochNeutralized

    # Must acknowledge before re-pinning
    let unpinned = unpinResult.epochneutralized.acknowledge()

    # Now can pin again
    let pinned2 = unpinned.handle.pin()
    check manager.threads[handle.idx].pinned.load(moAcquire) == true
    discard pinned2.unpin()
