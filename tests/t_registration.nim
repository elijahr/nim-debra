# tests/t_registration.nim

import unittest2
import atomics

import debra/types
import debra/typestates/registration

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
