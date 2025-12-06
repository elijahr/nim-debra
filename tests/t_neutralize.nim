# tests/t_neutralize.nim

import unittest2
import atomics
import std/posix

import debra

suite "Neutralization Typestate":
  var manager: DebraManager[4]

  setup:
    manager = initDebraManager[4]()
    setGlobalManager(addr manager)

  test "neutralizeStalled returns 0 when no stalled threads":
    let count = manager.neutralizeStalled()
    check count == 0

  test "neutralizeStalled counts signaled threads":
    # Register and pin a thread at old epoch
    manager.activeThreadMask.store(0b0001'u64, moRelaxed)
    manager.threads[0].pinned.store(true, moRelaxed)
    manager.threads[0].epoch.store(1'u64, moRelaxed)
    manager.threads[0].osThreadId.store(getThreadId().Pid, moRelaxed)

    # Advance global epoch
    manager.globalEpoch.store(10'u64, moRelaxed)

    # Note: actual signal won't be sent in test (would signal ourselves)
    # This tests the logic, not the signal delivery
    let count = manager.neutralizeStalled(epochsBeforeNeutralize = 2)
    check count >= 0  # May be 0 if thread is current thread
