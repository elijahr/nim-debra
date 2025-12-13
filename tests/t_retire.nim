import unittest2
import atomics

import debra/types
import debra/limbo
import debra/managed
import debra/typestates/manager
import debra/typestates/guard
import debra/typestates/retire

var testFreed: int = 0
proc testDestructor(p: pointer) {.nimcall.} =
  inc testFreed

suite "Retire typestate":
  var mgr: DebraManager[4]

  setup:
    testFreed = 0
    mgr = DebraManager[4]()
    discard uninitializedManager(addr mgr).initialize()

  test "retireReady from Pinned":
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    let ready = retireReady(p)
    check ready is RetireReady[4]

  test "retire adds object to limbo bag":
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    let ready = retireReady(p)
    let retired = ready.retire(nil, testDestructor)
    check retired is Retired[4]
    check mgr.threads[0].currentBag != nil
    check mgr.threads[0].currentBag.count == 1

  test "retire multiple objects fills bag":
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    var ready = retireReady(p)
    for i in 0..<LimboBagSize:
      let retired = ready.retire(nil, testDestructor)
      ready = retireReadyFromRetired(retired)
    check mgr.threads[0].currentBag.count == LimboBagSize

suite "Retire typestate with Managed":
  var mgr: DebraManager[4]

  setup:
    mgr = DebraManager[4]()
    discard uninitializedManager(addr mgr).initialize()

  test "retire accepts Managed[T]":
    type Node = ref object
      value: int

    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    let ready = retireReady(p)

    let node = managed Node(value: 42)
    let retired = ready.retire(node)

    check retired is Retired[4]
    check mgr.threads[0].currentBag != nil
    check mgr.threads[0].currentBag.count == 1

  test "retire multiple Managed objects":
    type Node = ref object
      value: int

    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    var ready = retireReady(p)

    for i in 0..<5:
      let node = managed Node(value: i)
      let retired = ready.retire(node)
      ready = retireReadyFromRetired(retired)

    check mgr.threads[0].currentBag.count == 5
