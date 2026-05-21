import unittest2

import debra/atomics
import debra/types
import debra/limbo
import debra/typestates/manager
import debra/typestates/guard
import debra/typestates/retire

type NodeObj = object
  value: int

proc dtor(p: pointer) {.nimcall.} =
  dealloc(p)

suite "Retire typestate":
  var mgr: DebraManager[4]

  setup:
    mgr = DebraManager[4]()
    discard uninitializedManager(addr mgr).initialize()

  test "retireReady from Pinned":
    let handle = ThreadHandle[4, ccSingle](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    let ready = retireReady(p)
    check ready is RetireReady[4, ccSingle]

  test "retire accepts pointer + destructor":
    let handle = ThreadHandle[4, ccSingle](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    let ready = retireReady(p)

    let raw = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    raw.value = 42
    let retired = ready.retire(cast[pointer](raw), dtor)

    check retired is Retired[4, ccSingle]
    check mgr.threads[0].currentBag != nil
    check mgr.threads[0].currentBag.count == 1

  test "retire multiple pointers fills bag":
    let handle = ThreadHandle[4, ccSingle](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    var ready = retireReady(p)

    for i in 0 ..< LimboBagSize:
      let raw = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
      raw.value = i
      let retired = ready.retire(cast[pointer](raw), dtor)
      ready = retireReadyFromRetired(retired)

    check mgr.threads[0].currentBag.count == LimboBagSize

  test "retireReadyFromRetired allows chaining":
    let handle = ThreadHandle[4, ccSingle](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    var ready = retireReady(p)

    for i in 0 ..< 3:
      let raw = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
      raw.value = i
      let retired = ready.retire(cast[pointer](raw), dtor)
      ready = retireReadyFromRetired(retired)

    check mgr.threads[0].currentBag.count == 3

  test "pinnedFromRetired round-trips Pinned -> Retired -> Pinned -> unpin":
    let handle = ThreadHandle[4, ccSingle](idx: 0, manager: addr mgr)
    let pinned = unpinned(handle).pin()
    let originalEpoch = pinned.epoch
    let ready = retireReady(pinned)

    let raw = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    raw.value = 7
    let retired = ready.retire(cast[pointer](raw), dtor)

    # Slot must still be pinned: the typestate has consumed Retired into
    # a fresh Pinned without ever flipping the slot's `pinned` flag.
    check mgr.threads[0].pinned.load(moAcquire) == true

    let pinnedAgain = pinnedFromRetired(retired)
    check pinnedAgain.epoch == originalEpoch
    check pinnedAgain.handle.idx == handle.idx

    # The retire we did beforehand is still recorded.
    check mgr.threads[0].currentBag != nil
    check mgr.threads[0].currentBag.count == 1

    # And we can unpin from the rebranded Pinned to close the lifecycle.
    discard pinnedAgain.unpin()
    check mgr.threads[0].pinned.load(moAcquire) == false
