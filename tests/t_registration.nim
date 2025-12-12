import unittest2
import atomics

import debra/types
import debra/typestates/registration
import debra/typestates/manager

type
  ConcurrentRegTestData* = object
    manager: ptr DebraManager[4]
    registrationResult: RegisterResult[4]

var
  globalThreadData: array[4, ConcurrentRegTestData]
  globalReadyCount: Atomic[int]
  globalGoFlag: Atomic[bool]
  globalThreadIds: Atomic[int]

proc concurrentRegisterProc() {.thread.} =
  # Claim a thread ID
  let myId = globalThreadIds.fetchAdd(1, moRelaxed)

  # Signal ready
  discard globalReadyCount.fetchAdd(1, moRelease)

  # Wait for go signal
  while not globalGoFlag.load(moAcquire):
    discard

  # Attempt registration
  let u = unregistered(globalThreadData[myId].manager)
  globalThreadData[myId].registrationResult = u.register()

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

  test "concurrent registration under contention":
    # Test the CAS loop under concurrent access from multiple threads
    var threads: array[4, Thread[void]]

    # Initialize synchronization primitives
    globalReadyCount.store(0, moRelaxed)
    globalGoFlag.store(false, moRelaxed)
    globalThreadIds.store(0, moRelaxed)

    # Initialize thread data
    for i in 0..<4:
      globalThreadData[i].manager = addr mgr

    # Start all threads
    for i in 0..<4:
      createThread(threads[i], concurrentRegisterProc)

    # Wait for all threads to be ready
    while globalReadyCount.load(moAcquire) < 4:
      discard

    # Release all threads simultaneously
    globalGoFlag.store(true, moRelease)

    # Wait for all threads to complete
    for i in 0..<4:
      joinThread(threads[i])

    # Verify all registrations succeeded
    for i in 0..<4:
      check globalThreadData[i].registrationResult.kind == rRegistered

    # Verify each thread got a unique slot index
    var seenIndices: set[0..3]
    for i in 0..<4:
      let idx = globalThreadData[i].registrationResult.registered.idx
      check idx >= 0
      check idx < 4
      check idx notin seenIndices
      seenIndices.incl(idx)

    # Verify all 4 slots are claimed (all bits set)
    let activeMask = mgr.activeThreadMask.load(moRelaxed)
    check activeMask == 0b1111'u64
