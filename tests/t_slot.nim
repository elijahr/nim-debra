import unittest2
import atomics

import debra/types
import debra/typestates/slot

suite "ThreadSlot typestate":
  var mgr: DebraManager[4]

  setup:
    mgr = initDebraManager[4]()

  test "free creates Free state":
    let slot = freeSlot[4](0, addr mgr)
    check slot is Free[4]

  test "claim transitions Free to Claiming":
    let slot = freeSlot[4](0, addr mgr)
    let claiming = slot.claim()
    check claiming is Claiming[4]

  test "activate transitions Claiming to Active":
    let slot = freeSlot[4](0, addr mgr)
    let claiming = slot.claim()
    let active = claiming.activate()
    check active is Active[4]

  test "drain transitions Active to Draining":
    let slot = freeSlot[4](0, addr mgr)
    let active = slot.claim().activate()
    let draining = active.drain()
    check draining is Draining[4]

  test "release transitions Draining to Free":
    let slot = freeSlot[4](0, addr mgr)
    let draining = slot.claim().activate().drain()
    let freed = draining.release()
    check freed is Free[4]

  test "complete lifecycle works":
    # Free -> Claiming -> Active -> Draining -> Free
    let slot1 = freeSlot[4](0, addr mgr)
    let claiming1 = slot1.claim()
    let active1 = claiming1.activate()
    let draining1 = active1.drain()
    let freed1 = draining1.release()
    check freed1 is Free[4]

  test "can claim again after release":
    let slot1 = freeSlot[4](0, addr mgr)
    let freed1 = slot1.claim().activate().drain().release()
    let claiming2 = freed1.claim()
    check claiming2 is Claiming[4]
