# tests/t_guard.nim

import unittest2
import atomics

import debra

suite "Epoch Guard Typestate":
  var manager: DebraManager[4]
  var handle: ThreadHandle[4]

  setup:
    manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    handle = registerThread(manager)

  test "pin sets pinned flag":
    let pinned = handle.pin()
    check manager.threads[handle.idx].pinned.load(moAcquire) == true

  test "unpin clears pinned flag":
    let pinned = handle.pin()
    discard pinned.unpin()
    check manager.threads[handle.idx].pinned.load(moAcquire) == false

  test "pin stores current epoch":
    manager.globalEpoch.store(42'u64, moRelaxed)
    let pinned = handle.pin()
    check manager.threads[handle.idx].epoch.load(moAcquire) == 42'u64

  test "unpin returns Unpinned when not neutralized":
    let pinned = handle.pin()
    let result = pinned.unpin()
    check result.kind == uEpochUnpinned

  test "unpin returns Neutralized when neutralized":
    let pinned = handle.pin()
    # Simulate signal handler setting neutralized
    manager.threads[handle.idx].neutralized.store(true, moRelease)
    let result = pinned.unpin()
    check result.kind == uEpochNeutralized
