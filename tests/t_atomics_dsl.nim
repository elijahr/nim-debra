# tests/t_atomics_dsl.nim
##
## Tests for debra/atomics/dsl: symmetric shorthand for load/store.

import unittest2

import debra/atomics
import debra/atomics/dsl

suite "DSL roundtrips":
  test "relaxed load and store":
    var a: Atomic[int]
    a.relaxed(42)
    check a.relaxed() == 42

  test "acquire load (load-only)":
    var a: Atomic[int]
    a.relaxed(7)
    check a.acquire() == 7

  test "release store (store-only)":
    var a: Atomic[int]
    a.release(99)
    check a.relaxed() == 99

  test "sequential load and store":
    var a: Atomic[int]
    a.sequential(123)
    check a.sequential() == 123

  test "DSL on ptr type":
    var x: int = 11
    var a: Atomic[ptr int]
    a.release(addr x)
    check a.acquire() == addr x

  test "DSL on bool type":
    var a: Atomic[bool]
    a.relaxed(true)
    check a.relaxed() == true
    a.sequential(false)
    check a.acquire() == false

suite "DSL methods exist via the dsl import":
  test "relaxed/acquire/release/sequential are callable":
    var a: Atomic[int]
    a.relaxed(1)
    check a.relaxed() == 1
    check a.acquire() == 1
    a.release(2)
    check a.sequential() == 2
    a.sequential(3)
    check a.sequential() == 3

# ---------------------------------------------------------------------------
# Opt-in verification: the DSL methods must NOT be reachable from a
# context that imports only `debra/atomics`. We can't undo our own
# top-level import, so we shell out to a helper proc compiled in a
# separate scope by `compiles()` against a fresh `staticExec`-style
# test. The cheapest reliable way in-process is to assert that the
# core module's surface does not contain the symbol by name.
#
# Implementation: instantiate a generic that takes a `var Atomic[int]`
# and tries to invoke the DSL via `compiles`. Once we drop the dsl
# import from this file's view (we cannot), we instead verify the
# negative case by running `nim check` on a sibling file. That file
# is `tests/t_atomics_dsl_negative.nim` (compile-only, no test
# harness).
# ---------------------------------------------------------------------------
