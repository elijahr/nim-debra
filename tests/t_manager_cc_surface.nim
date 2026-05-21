## Surface-ergonomics fixture for the 0.8.0 "Step 8" widening: verifies
## that `bindClient`, `unbindClient`, `clientCount`, `advance`,
## `currentEpoch`, and `initDebraManager` accept both `ccSingle` and
## `ccMulti` cardinality on `DebraManager` without triggering Nim's
## default-CC `type mismatch`.
##
## ccSingle behavior is already covered by `t_bind_client.nim` and other
## suites; this file exists to lock in the new ccMulti compile shape.

import unittest2

import debra
import debra/types
import debra/typestates/cardinality

suite "DebraManager CC surface (0.8.0 Step 8 widening)":
  test "initDebraManager[N]() defaults to ccSingle":
    var mgr = initDebraManager[4]()
    static:
      doAssert typeof(mgr) is DebraManager[4, ccSingle]
    check mgr.clientCount() == 0

  test "initDebraManager[N, ccSingle]() yields a ccSingle manager":
    var mgr = initDebraManager[4, ccSingle]()
    static:
      doAssert typeof(mgr) is DebraManager[4, ccSingle]
    check mgr.clientCount() == 0

  test "initDebraManager[N, ccMulti]() yields a ccMulti manager":
    var mgr = initDebraManager[4, ccMulti]()
    static:
      doAssert typeof(mgr) is DebraManager[4, ccMulti]
    check mgr.clientCount() == 0

  test "bindClient / unbindClient / clientCount accept ccMulti managers":
    var mgr = initDebraManager[4, ccMulti]()
    mgr.bindClient()
    mgr.bindClient()
    check mgr.clientCount() == 2
    mgr.unbindClient()
    mgr.unbindClient()
    check mgr.clientCount() == 0

  test "advance / currentEpoch accept ccMulti managers":
    var mgr = initDebraManager[4, ccMulti]()
    let e0 = mgr.currentEpoch()
    mgr.advance()
    let e1 = mgr.currentEpoch()
    check e1 == e0 + 1

  test "ccSingle and ccMulti managers are distinct compile-time types":
    var mgrSingle = initDebraManager[4, ccSingle]()
    var mgrMulti = initDebraManager[4, ccMulti]()
    static:
      doAssert typeof(mgrSingle) isnot typeof(mgrMulti)
    # Touch both to keep the values used and exercise the surface.
    mgrSingle.bindClient()
    mgrMulti.bindClient()
    check mgrSingle.clientCount() == 1
    check mgrMulti.clientCount() == 1
    mgrSingle.unbindClient()
    mgrMulti.unbindClient()
