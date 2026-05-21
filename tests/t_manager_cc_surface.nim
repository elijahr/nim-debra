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

suite "Typestate-context CC threading (0.8.0 Step 8 completion)":
  # Step 3.3.4.5a-2 completes the surface widening on the 5 typestate
  # context types (ReclaimContext, AdvanceContext, ManagerContext,
  # NeutralizeContext, SlotContext) that were missed in the original
  # 3.3.4.5a pass. This suite locks in that the ccMulti cardinality
  # propagates end-to-end through the typestate context builders and
  # transitions, mirroring the t_pinned_scope ccMulti fixture for the
  # already-widened guard/retire/pinned_scope contexts.

  test "uninitializedManager / initialize / shutdown accept ccMulti":
    var mgr = initDebraManager[4, ccMulti]()
    let uninit = uninitializedManager(addr mgr)
    static:
      doAssert typeof(uninit) is ManagerUninitialized[4, ccMulti]
    let ready = uninit.initialize()
    static:
      doAssert typeof(ready) is ManagerReady[4, ccMulti]
    let shutdown = ready.shutdown()
    static:
      doAssert typeof(shutdown) is ManagerShutdown[4, ccMulti]

  test "advanceCurrent / advance / complete accept ccMulti":
    var mgr = initDebraManager[4, ccMulti]()
    let current = advanceCurrent(addr mgr)
    static:
      doAssert typeof(current) is Current[4, ccMulti]
    let advanced = current.advance().complete()
    static:
      doAssert typeof(advanced) is Advanced[4, ccMulti]
    check advanced.newEpoch == advanced.oldEpoch + 1'u64

  test "freeSlot / claim / activate / drain / release accept ccMulti":
    var mgr = initDebraManager[4, ccMulti]()
    let free0 = freeSlot[4, ccMulti](0, addr mgr)
    static:
      doAssert typeof(free0) is Free[4, ccMulti]
    let claiming = free0.claim()
    static:
      doAssert typeof(claiming) is Claiming[4, ccMulti]
    let active = claiming.activate()
    static:
      doAssert typeof(active) is Active[4, ccMulti]
    check active.idx == 0
    let draining = active.drain()
    static:
      doAssert typeof(draining) is Draining[4, ccMulti]
    let free1 = draining.release()
    static:
      doAssert typeof(free1) is Free[4, ccMulti]

  test "scanStart / loadEpoch / scanAndSignal accept ccMulti":
    var mgr = initDebraManager[4, ccMulti]()
    let s = scanStart(addr mgr)
    static:
      doAssert typeof(s) is ScanStart[4, ccMulti]
    let scanning = s.loadEpoch()
    static:
      doAssert typeof(scanning) is Scanning[4, ccMulti]
    let complete = scanning.scanAndSignal()
    static:
      doAssert typeof(complete) is ScanComplete[4, ccMulti]
    # No registered threads -> no signals sent.
    check complete.signalsSent == 0

  test "reclaimStart(handle) chain accepts ccMulti — load-bearing block site":
    # This is the lfq v5.0.0 reclaim.nim:97 shape: a ccMulti handle reaches
    # reclaimStart, which previously required a ccSingle context and rejected
    # the ccMulti manager. Verifies the full chain reclaimStart -> loadEpochs
    # -> checkSafe -> tryReclaim propagates CC end-to-end.
    var mgr = initDebraManager[4, ccMulti]()
    discard uninitializedManager(addr mgr).initialize()
    let handle = registerThread(mgr)
    static:
      doAssert typeof(handle) is ThreadHandle[4, ccMulti]
    let s = reclaimStart(handle)
    static:
      doAssert typeof(s) is ReclaimStart[4, ccMulti]
    let loaded = s.loadEpochs()
    static:
      doAssert typeof(loaded) is EpochsLoaded[4, ccMulti]
    let checked = loaded.checkSafe()
    static:
      doAssert typeof(checked) is ReclaimCheck[4, ccMulti]
    # Brand-new manager, advance twice so safeEpoch > 1 and the ReclaimReady
    # branch is the one observed.
    mgr.advance()
    mgr.advance()
    let count = reclaimNow(handle)
    check count == 0 # nothing retired

  test "reclaimNow(handle) end-to-end on ccMulti propagates through tryReclaim":
    # Exercises the convenience wrapper path that lockfreequeues v5.0.0
    # multi-consumer pop hits at its reclaimNow tail.
    var mgr = initDebraManager[4, ccMulti]()
    discard uninitializedManager(addr mgr).initialize()
    let handle = registerThread(mgr)
    proc dtor(p: pointer) {.nimcall.} =
      dealloc(p)

    block:
      var scope = pinScope(unpinned(handle))
      var ready = retireReady(scope.state)
      ready.retire(alloc0(8), dtor)
    mgr.advance()
    mgr.advance()
    let reclaimed = reclaimNow(handle)
    check reclaimed == 1

  test "reclaimNow(manager) legacy form accepts ccMulti":
    var mgr = initDebraManager[4, ccMulti]()
    discard uninitializedManager(addr mgr).initialize()
    discard registerThread(mgr)
    # No retires yet, no advance: returns 0 cleanly without a ccSingle mismatch.
    let n = reclaimNow(mgr)
    check n == 0
