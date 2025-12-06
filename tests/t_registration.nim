# tests/t_registration.nim

import unittest2
import atomics

import debra/types
import debra/typestates/registration
import debra

suite "Thread Registration Typestate":
  var manager: DebraManager[4]

  setup:
    manager = initDebraManager[4]()

  test "start returns ThreadUnregistered":
    let op = start()
    check op is ThreadUnregistered

  test "findSlot finds slot 0 when all empty":
    let op = start()
    let slotCheck = op.findSlot(manager)
    check slotCheck.kind == sThreadSlotFound
    check slotCheck.threadslotfound.slotIdx == 0

  test "findSlot returns Full when all slots taken":
    # Mark all slots as taken
    manager.activeThreadMask.store(0b1111'u64, moRelaxed)
    let op = start()
    let slotCheck = op.findSlot(manager)
    check slotCheck.kind == sThreadRegistrationFull

suite "registerThread API":
  var manager: DebraManager[4]

  setup:
    manager = initDebraManager[4]()
    setGlobalManager(addr manager)

  test "registerThread returns valid handle":
    let handle = registerThread(manager)
    check handle.idx >= 0
    check handle.idx < 4

  test "registerThread raises when full":
    # Register 4 threads (max)
    discard registerThread(manager)
    discard registerThread(manager)
    discard registerThread(manager)
    discard registerThread(manager)

    expect DebraRegistrationError:
      discard registerThread(manager)
