import unittest2
import atomics

import debra/types
import debra/typestates/advance

suite "EpochAdvance typestate":
  var mgr: DebraManager[4]

  setup:
    mgr = initDebraManager[4]()

  test "advanceCurrent creates Current state":
    let current = advanceCurrent(addr mgr)
    check current is Current[4]

  test "advance transitions Current to Advancing":
    let current = advanceCurrent(addr mgr)
    let advancing = current.advance()
    check advancing is Advancing[4]

  test "complete transitions Advancing to Advanced":
    mgr.globalEpoch.store(5'u64, moRelaxed)
    let current = advanceCurrent(addr mgr)
    let advancing = current.advance()
    let advanced = advancing.complete()
    check advanced is Advanced[4]
    # Verify epoch was incremented
    check mgr.globalEpoch.load(moAcquire) == 6'u64

  test "advance increments epoch atomically":
    mgr.globalEpoch.store(10'u64, moRelaxed)
    let advanced = advanceCurrent(addr mgr).advance().complete()
    check mgr.globalEpoch.load(moAcquire) == 11'u64
    check advanced.newEpoch == 11'u64

  test "newEpoch accessor returns incremented value":
    mgr.globalEpoch.store(3'u64, moRelaxed)
    let advanced = advanceCurrent(addr mgr).advance().complete()
    check advanced.newEpoch == 4'u64
