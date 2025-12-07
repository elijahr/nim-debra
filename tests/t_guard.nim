import unittest2
import atomics

import debra/types
import debra/typestates/manager
import debra/typestates/guard

suite "EpochGuard typestate":
  var mgr: DebraManager[4]

  setup:
    mgr = DebraManager[4]()
    discard uninitializedManager(addr mgr).initialize()

  test "unpinned creates Unpinned state":
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let u = unpinned(handle)
    check u is Unpinned[4]

  test "pin transitions Unpinned to Pinned":
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let u = unpinned(handle)
    let p = u.pin()
    check p is Pinned[4]
    check mgr.threads[0].pinned.load(moAcquire) == true

  test "unpin transitions Pinned to UnpinResult":
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    let result = p.unpin()
    check result.kind == uUnpinned
    check mgr.threads[0].pinned.load(moAcquire) == false

  test "unpin detects neutralization":
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    mgr.threads[0].neutralized.store(true, moRelease)
    let result = p.unpin()
    check result.kind == uNeutralized

  test "acknowledge transitions Neutralized to Unpinned":
    let handle = ThreadHandle[4](idx: 0, manager: addr mgr)
    let p = unpinned(handle).pin()
    mgr.threads[0].neutralized.store(true, moRelease)
    let result = p.unpin()
    let u = result.neutralized.acknowledge()
    check u is Unpinned[4]
    check mgr.threads[0].neutralized.load(moAcquire) == false
