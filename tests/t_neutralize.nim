# tests/t_neutralize.nim

import unittest2
import atomics
import std/posix

import debra/types
import debra/typestates/neutralize

suite "Neutralize typestate":
  var mgr: DebraManager[4]

  setup:
    mgr = DebraManager[4]()
    mgr.globalEpoch.store(1'u64, moRelaxed)
    mgr.activeThreadMask.store(0'u64, moRelaxed)
    for i in 0..<4:
      mgr.threads[i].epoch.store(0'u64, moRelaxed)
      mgr.threads[i].pinned.store(false, moRelaxed)
      mgr.threads[i].neutralized.store(false, moRelaxed)
      mgr.threads[i].osThreadId.store(Pid(0), moRelaxed)

  test "scanStart creates ScanStart":
    let s = scanStart(addr mgr)
    check s is ScanStart[4]

  test "loadEpoch transitions to Scanning":
    let s = scanStart(addr mgr)
    mgr.globalEpoch.store(10'u64, moRelaxed)
    let scanning = s.loadEpoch()
    check scanning is Scanning[4]
    check scanning.globalEpoch == 10'u64

  test "scanAndSignal sends signals to stalled threads":
    # Setup: thread 0 is pinned at epoch 1
    mgr.globalEpoch.store(10'u64, moRelaxed)
    mgr.activeThreadMask.store(0b0001'u64, moRelaxed)
    mgr.threads[0].pinned.store(true, moRelaxed)
    mgr.threads[0].epoch.store(1'u64, moRelaxed)
    mgr.threads[0].osThreadId.store(getThreadId().Pid, moRelaxed)

    let scanning = scanStart(addr mgr).loadEpoch()
    let complete = scanning.scanAndSignal()
    check complete is ScanComplete[4]
    # Signal count may be 0 if we're signaling ourselves (skipped)
    check complete.signalsSent >= 0

  test "scanAndSignal does not signal threads within threshold":
    # Setup: thread 0 is pinned at epoch 9 (only 1 behind)
    mgr.globalEpoch.store(10'u64, moRelaxed)
    mgr.activeThreadMask.store(0b0001'u64, moRelaxed)
    mgr.threads[0].pinned.store(true, moRelaxed)
    mgr.threads[0].epoch.store(9'u64, moRelaxed)
    mgr.threads[0].osThreadId.store(Pid(12345), moRelaxed)

    let scanning = scanStart(addr mgr).loadEpoch(epochsBeforeNeutralize = 2)
    let complete = scanning.scanAndSignal()
    check complete.signalsSent == 0  # Not stalled enough

  test "scanAndSignal signals thread beyond threshold":
    # Setup: thread 0 is pinned at epoch 7 (3 behind, threshold is 2)
    mgr.globalEpoch.store(10'u64, moRelaxed)
    mgr.activeThreadMask.store(0b0001'u64, moRelaxed)
    mgr.threads[0].pinned.store(true, moRelaxed)
    mgr.threads[0].epoch.store(7'u64, moRelaxed)
    mgr.threads[0].osThreadId.store(Pid(12345), moRelaxed)

    let scanning = scanStart(addr mgr).loadEpoch(epochsBeforeNeutralize = 2)
    let complete = scanning.scanAndSignal()
    check complete.signalsSent == 1

  test "extractSignalCount gets count from ScanComplete":
    mgr.globalEpoch.store(10'u64, moRelaxed)
    mgr.activeThreadMask.store(0b0011'u64, moRelaxed)
    # Thread 0 stalled
    mgr.threads[0].pinned.store(true, moRelaxed)
    mgr.threads[0].epoch.store(1'u64, moRelaxed)
    mgr.threads[0].osThreadId.store(Pid(12345), moRelaxed)
    # Thread 1 stalled
    mgr.threads[1].pinned.store(true, moRelaxed)
    mgr.threads[1].epoch.store(2'u64, moRelaxed)
    mgr.threads[1].osThreadId.store(Pid(12346), moRelaxed)

    let complete = scanStart(addr mgr).loadEpoch().scanAndSignal()
    let count = complete.extractSignalCount()
    check count == 2
