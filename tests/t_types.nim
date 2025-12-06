# tests/t_types.nim

import unittest2
import atomics

import debra/types

suite "ThreadState":
  test "initial state is unpinned":
    var state: ThreadState[64]
    check state.pinned.load(moRelaxed) == false
    check state.neutralized.load(moRelaxed) == false
    check state.epoch.load(moRelaxed) == 0'u64

suite "DebraManager":
  test "initial global epoch is 1":
    var manager = initDebraManager[64]()
    check manager.globalEpoch.load(moRelaxed) == 1'u64

  test "no active threads initially":
    var manager = initDebraManager[64]()
    check manager.activeThreadMask.load(moRelaxed) == 0'u64

  test "all thread states unpinned initially":
    var manager = initDebraManager[64]()
    for i in 0..<64:
      check manager.threads[i].pinned.load(moRelaxed) == false
