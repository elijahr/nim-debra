import unittest2
import atomics

import debra/types
import debra/typestates/manager

suite "Manager typestate":
  test "uninitializedManager creates ManagerUninitialized":
    var mgr: DebraManager[4]
    let ctx = uninitializedManager(addr mgr)
    check ctx is ManagerUninitialized[4]

  test "initialize transitions to ManagerReady":
    var mgr: DebraManager[4]
    let uninit = uninitializedManager(addr mgr)
    let ready = uninit.initialize()
    check ready is ManagerReady[4]
    # Verify initialization happened
    check mgr.globalEpoch.load(moRelaxed) == 1'u64

  test "shutdown transitions to ManagerShutdown":
    var mgr: DebraManager[4]
    let ready = uninitializedManager(addr mgr).initialize()
    let shutdown = ready.shutdown()
    check shutdown is ManagerShutdown[4]
