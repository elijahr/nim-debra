# tests/test_dwcas_roundtrip.nim
##
## DWCAS unit round-trip suite (impl plan Task 13).
##
## Exhaustively exercises every public DWCAS entry point on
## `Atomic[Pair[uint64, uint64]]`: load (default + explicit-order),
## store (default + explicit-order), exchange (default + explicit-order),
## compareExchangeStrong (3 overloads), compareExchangeWeak (3 overloads),
## compareExchange aliases (3 overloads). 14 entry points total.
##
## Wired into `tests/test.nim` so it runs under arc / orc / atomicArc /
## refc via the `nimble test` task. Each test verifies return value and
## post-state side effects on both success and failure paths.
##
## Existing t_atomics.nim DWCAS suites cover the basic surface; this file
## is the systematic per-overload audit Task 13 calls for.

import unittest2

import debra/atomics

type P = Pair[uint64, uint64]

template mkP(a, b: uint64): P =
  Pair[uint64, uint64](first: a, second: b)

suite "DWCAS round-trip: load overloads":
  test "load() default-order returns seeded bits":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    let r = a.load()
    check r.first == 1'u64
    check r.second == 2'u64

  test "load(moSequentiallyConsistent) explicit-order returns seeded bits":
    var a: Atomic[P]
    a.store(mkP(3'u64, 4'u64))
    let r = a.load(moSequentiallyConsistent)
    check r.first == 3'u64
    check r.second == 4'u64

suite "DWCAS round-trip: store overloads":
  test "store(desired) default-order writes value":
    var a: Atomic[P]
    a.store(mkP(5'u64, 6'u64))
    check a.load() == mkP(5'u64, 6'u64)

  test "store(desired, moSequentiallyConsistent) writes value":
    var a: Atomic[P]
    a.store(mkP(7'u64, 8'u64), moSequentiallyConsistent)
    check a.load() == mkP(7'u64, 8'u64)

suite "DWCAS round-trip: exchange overloads":
  test "exchange(desired) default-order returns prior, installs new":
    var a: Atomic[P]
    a.store(mkP(10'u64, 20'u64))
    let prev = a.exchange(mkP(30'u64, 40'u64))
    check prev == mkP(10'u64, 20'u64)
    check a.load() == mkP(30'u64, 40'u64)

  test "exchange(desired, moSequentiallyConsistent) returns prior, installs new":
    var a: Atomic[P]
    a.store(mkP(11'u64, 22'u64))
    let prev = a.exchange(mkP(33'u64, 44'u64), moSequentiallyConsistent)
    check prev == mkP(11'u64, 22'u64)
    check a.load() == mkP(33'u64, 44'u64)

suite "DWCAS round-trip: compareExchangeStrong overloads":
  test "3-arg default-order: success path updates slot, expected unchanged":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(1'u64, 2'u64)
    check a.compareExchangeStrong(expected, mkP(5'u64, 6'u64))
    check expected == mkP(1'u64, 2'u64)
    check a.load() == mkP(5'u64, 6'u64)

  test "3-arg default-order: failure path leaves slot, overwrites expected":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(99'u64, 99'u64)
    check (not a.compareExchangeStrong(expected, mkP(5'u64, 6'u64)))
    check expected == mkP(1'u64, 2'u64)
    check a.load() == mkP(1'u64, 2'u64)

  test "4-arg single-order: success path":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(1'u64, 2'u64)
    check a.compareExchangeStrong(expected, mkP(7'u64, 8'u64), moSequentiallyConsistent)
    check a.load() == mkP(7'u64, 8'u64)

  test "4-arg single-order: failure path":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(99'u64, 99'u64)
    check (
      not a.compareExchangeStrong(expected, mkP(7'u64, 8'u64), moSequentiallyConsistent)
    )
    check expected == mkP(1'u64, 2'u64)

  test "5-arg explicit success+failure orders: success path":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(1'u64, 2'u64)
    check a.compareExchangeStrong(
      expected, mkP(9'u64, 10'u64), moSequentiallyConsistent, moSequentiallyConsistent
    )
    check a.load() == mkP(9'u64, 10'u64)

  test "5-arg explicit success+failure orders: failure path":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(99'u64, 99'u64)
    check (
      not a.compareExchangeStrong(
        expected, mkP(9'u64, 10'u64), moSequentiallyConsistent, moSequentiallyConsistent
      )
    )
    check expected == mkP(1'u64, 2'u64)

suite "DWCAS round-trip: compareExchangeWeak overloads":
  # Weak CAS may spuriously fail on aarch64 LL/SC; retry to decisive outcome.
  const SpuriousRetries = 64

  test "4-arg single-order weak: eventual success":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var ok = false
    for _ in 0 ..< SpuriousRetries:
      a.store(mkP(1'u64, 2'u64))
      var expected = mkP(1'u64, 2'u64)
      if a.compareExchangeWeak(expected, mkP(5'u64, 6'u64), moSequentiallyConsistent):
        ok = true
        break
    check ok
    check a.load() == mkP(5'u64, 6'u64)

  test "4-arg single-order weak: definitive failure on mismatch":
    # A genuine mismatch must return false regardless of spurious flag.
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(99'u64, 99'u64)
    check (
      not a.compareExchangeWeak(expected, mkP(5'u64, 6'u64), moSequentiallyConsistent)
    )
    check expected == mkP(1'u64, 2'u64)
    check a.load() == mkP(1'u64, 2'u64)

  test "5-arg explicit-orders weak: eventual success":
    var a: Atomic[P]
    var ok = false
    for _ in 0 ..< SpuriousRetries:
      a.store(mkP(1'u64, 2'u64))
      var expected = mkP(1'u64, 2'u64)
      if a.compareExchangeWeak(
        expected,
        mkP(11'u64, 12'u64),
        moSequentiallyConsistent,
        moSequentiallyConsistent,
      ):
        ok = true
        break
    check ok
    check a.load() == mkP(11'u64, 12'u64)

  test "5-arg explicit-orders weak: definitive failure on mismatch":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(99'u64, 99'u64)
    check (
      not a.compareExchangeWeak(
        expected,
        mkP(11'u64, 12'u64),
        moSequentiallyConsistent,
        moSequentiallyConsistent,
      )
    )
    check expected == mkP(1'u64, 2'u64)

  test "3-arg default-order weak: eventual success":
    # Default-order overload mirrors Strong's zero-extra-arg form.
    # Equivalent to passing moSequentiallyConsistent for both orders.
    var a: Atomic[P]
    var ok = false
    for _ in 0 ..< SpuriousRetries:
      a.store(mkP(1'u64, 2'u64))
      var expected = mkP(1'u64, 2'u64)
      if a.compareExchangeWeak(expected, mkP(21'u64, 22'u64)):
        ok = true
        break
    check ok
    check a.load() == mkP(21'u64, 22'u64)

  test "3-arg default-order weak: definitive failure on mismatch":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(99'u64, 99'u64)
    check (not a.compareExchangeWeak(expected, mkP(21'u64, 22'u64)))
    check expected == mkP(1'u64, 2'u64)
    check a.load() == mkP(1'u64, 2'u64)

suite "DWCAS round-trip: compareExchange aliases":
  test "3-arg default-order alias routes to Strong":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(1'u64, 2'u64)
    check a.compareExchange(expected, mkP(3'u64, 4'u64))
    check a.load() == mkP(3'u64, 4'u64)

  test "4-arg single-order alias routes to Strong":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(1'u64, 2'u64)
    check a.compareExchange(expected, mkP(5'u64, 6'u64), moSequentiallyConsistent)
    check a.load() == mkP(5'u64, 6'u64)

  test "5-arg explicit-orders alias routes to Strong":
    var a: Atomic[P]
    a.store(mkP(1'u64, 2'u64))
    var expected = mkP(1'u64, 2'u64)
    check a.compareExchange(
      expected, mkP(7'u64, 8'u64), moSequentiallyConsistent, moSequentiallyConsistent
    )
    check a.load() == mkP(7'u64, 8'u64)
