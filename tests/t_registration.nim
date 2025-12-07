import unittest2
import atomics

import debra/types
import debra/typestates/registration
import debra/typestates/manager

suite "Registration typestate":
  var mgr: DebraManager[4]
  var ready: ManagerReady[4]

  setup:
    mgr = DebraManager[4]()
    ready = uninitializedManager(addr mgr).initialize()

  test "unregistered creates Unregistered state":
    let u = unregistered(addr mgr)
    check u is Unregistered[4]

  test "register transitions Unregistered -> Registered | RegistrationFull":
    let u = unregistered(addr mgr)
    let result = u.register()
    check result.kind == rRegistered
    check result.registered.idx >= 0
    check result.registered.idx < 4

  test "register returns RegistrationFull when all slots taken":
    # Fill all slots
    mgr.activeThreadMask.store(0b1111'u64, moRelaxed)
    let u = unregistered(addr mgr)
    let result = u.register()
    check result.kind == rRegistrationFull

  test "getHandle extracts ThreadHandle from Registered":
    let u = unregistered(addr mgr)
    let result = u.register()
    check result.kind == rRegistered
    let handle = result.registered.getHandle()
    check handle.idx >= 0
    check handle.manager == addr mgr

  test "multiple threads can register":
    let u1 = unregistered(addr mgr)
    let r1 = u1.register()
    check r1.kind == rRegistered
    check r1.registered.idx == 0

    let u2 = unregistered(addr mgr)
    let r2 = u2.register()
    check r2.kind == rRegistered
    check r2.registered.idx == 1
