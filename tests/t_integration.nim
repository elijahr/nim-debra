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
    let u = unpinned(handle)
    let pinned = u.pin()
    check manager.threads[handle.idx].pinned.load(moAcquire) == true

    # Advance epoch while pinned
    manager.advance()
    manager.advance()

    # Unpin
    let unpinResult = pinned.unpin()
    check unpinResult.kind == uUnpinned

    # Now reclamation should be possible
    let reclaim = reclaimStart(addr manager)
    let loaded = reclaim.loadEpochs()
    let checkResult = loaded.checkSafe()
    check checkResult.kind == rReclaimReady

  test "neutralization acknowledgment cycle":
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)

    let handle = registerThread(manager)

    # Pin
    let u = unpinned(handle)
    let pinned = u.pin()

    # Simulate being neutralized
    manager.threads[handle.idx].neutralized.store(true, moRelease)

    # Unpin should detect neutralization
    let unpinResult = pinned.unpin()
    check unpinResult.kind == uNeutralized

    # Must acknowledge before re-pinning
    let unpinned = unpinResult.neutralized.acknowledge()

    # Now can pin again
    let pinned2 = unpinned.pin()
    check manager.threads[handle.idx].pinned.load(moAcquire) == true
    discard pinned2.unpin()
