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
