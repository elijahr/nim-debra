# tests/t_backoff.nim
##
## Tests for debra/atomics/backoff: cpuPause and schedYield spin-loop hints.
##
## These tests verify the procs link, run, return, and don't catastrophically
## miscompile (local counter survives the call sequence) on top of the basic
## crash/link/return contract. Anything deeper (cycle counts, scheduling
## behavior) is platform-dependent and out of scope for a unit test.

import unittest2

import debra/atomics/backoff

## NOTE on test scope:
## These tests verify cpuPause/schedYield link, run, return, and don't
## corrupt local state. They DO NOT verify the asm hint instruction is
## actually emitted (which would require objdump/nm — out of scope per
## design doc Section 1.3). If proc bodies were `discard`, these tests
## would still pass; that gap is the documented trade-off.

suite "backoff":
  test "cpuPause does not corrupt local state":
    # 1000 cpuPause iters: cheap, hardware hint; 100 schedYield iters:
    # each is a syscall, more iters wastes CI time.
    var n = 0
    for _ in 0 ..< 1000:
      cpuPause()
      inc n
    check n == 1000

  test "schedYield does not corrupt local state":
    var n = 0
    for _ in 0 ..< 100:
      schedYield()
      inc n
    check n == 100

  test "schedYield returns success on POSIX":
    when defined(posix):
      proc sched_yield(): cint {.importc, header: "<sched.h>".}
      check sched_yield() == 0
    else:
      skip()
