# tests/test_dwcas_pair_ptr.nim
##
## Pair[uint64, ptr T] ARC zero-hook audit (impl plan Task 15, design §2.6
## F2 closure, HIGH-2).
##
## The LCRQ pattern stores `Pair[uint64, ptr T]` where `second` is a raw
## non-owning pointer. ARC/ORC must NOT generate `=destroy` / `=copy`
## hooks on the Pair type — any such hook would either touch the pointee
## (lifetime claim we explicitly disclaim per Pair docs) or insert ARC
## traffic into the DWCAS hot path.
##
## Runtime test: round-trip a heap-allocated `int` pointer through every
## DWCAS op and verify the pointee is intact after each. Wired into
## tests/test.nim — runs under arc/orc/atomicArc/refc.
##
## Compile-time audit (the actual F2 closure invariant) is performed by
## the companion script `tests/audit_dwcas_pair_arc.sh`, which runs
## `nim c --expandArc:auditProc` and asserts zero `=destroy` / `=copy`
## hooks fire on Pair. The script is wired into CI in a follow-up task.

import unittest2

import debra/atomics

type PP = Pair[uint64, ptr int]

suite "Pair[uint64, ptr int] DWCAS round-trip (no pointee corruption)":
  test "store/load: pointee value preserved":
    var x = 42
    let p = addr x
    var a: Atomic[PP]
    a.store(Pair[uint64, ptr int](first: 1'u64, second: p))
    let r = a.load()
    check r.first == 1'u64
    check r.second == p
    check r.second[] == 42

  test "exchange: prior pointer preserved, new installed, neither pointee corrupted":
    var x = 42
    var y = 99
    var a: Atomic[PP]
    a.store(Pair[uint64, ptr int](first: 1'u64, second: addr x))

    let prev = a.exchange(Pair[uint64, ptr int](first: 2'u64, second: addr y))
    check prev.first == 1'u64
    check prev.second == addr x
    check prev.second[] == 42

    let cur = a.load()
    check cur.first == 2'u64
    check cur.second == addr y
    check cur.second[] == 99

  test "compareExchangeStrong success: installed pointer reads back":
    var x = 42
    var y = 7
    var a: Atomic[PP]
    a.store(Pair[uint64, ptr int](first: 1'u64, second: addr x))

    var expected = Pair[uint64, ptr int](first: 1'u64, second: addr x)
    check a.compareExchangeStrong(
      expected, Pair[uint64, ptr int](first: 2'u64, second: addr y)
    )
    let cur = a.load()
    check cur.second == addr y
    check cur.second[] == 7

  test "compareExchangeStrong failure: pointee untouched, expected updated":
    var x = 42
    var y = 7
    var a: Atomic[PP]
    a.store(Pair[uint64, ptr int](first: 1'u64, second: addr x))

    var expected = Pair[uint64, ptr int](first: 99'u64, second: nil)
    check (
      not a.compareExchangeStrong(
        expected, Pair[uint64, ptr int](first: 2'u64, second: addr y)
      )
    )
    # Failure path: slot unchanged; expected overwritten with current.
    check expected.first == 1'u64
    check expected.second == addr x
    check expected.second[] == 42
    check x == 42 # original pointee intact

  test "compareExchangeStrong with nil second half":
    var a: Atomic[PP]
    a.store(Pair[uint64, ptr int](first: 1'u64, second: nil))
    var expected = Pair[uint64, ptr int](first: 1'u64, second: nil)
    check a.compareExchangeStrong(
      expected, Pair[uint64, ptr int](first: 2'u64, second: nil)
    )
    check a.load() == Pair[uint64, ptr int](first: 2'u64, second: nil)

# ---------------------------------------------------------------------------
# ARC-hook audit helper. Compiled via `--expandArc:auditDwcasPtrProc` by
# tests/audit_dwcas_pair_arc.sh; that script greps the expanded output for
# any `=destroy` / `=copy` invocations on Pair, asserting zero. The proc
# itself just needs to exercise every DWCAS entry point on Pair[uint64,
# ptr int] so the compiler emits its lowered form.
# ---------------------------------------------------------------------------

proc auditDwcasPtrProc*() =
  ## Exercise every DWCAS entry point on Pair[uint64, ptr int]. Compile
  ## with `--expandArc:auditDwcasPtrProc` to inspect ARC lowering.
  var x = 1
  var y = 2
  var a: Atomic[PP]
  a.store(Pair[uint64, ptr int](first: 1'u64, second: addr x))
  let _ = a.load()
  let _ = a.exchange(Pair[uint64, ptr int](first: 2'u64, second: addr y))
  var expected = a.load()
  let _ = a.compareExchangeStrong(
    expected, Pair[uint64, ptr int](first: 3'u64, second: addr x)
  )
  var expected2 = a.load()
  let _ = a.compareExchangeWeak(
    expected2, Pair[uint64, ptr int](first: 4'u64, second: addr y)
  )
