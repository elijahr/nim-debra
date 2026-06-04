# tests/test_dwcas_generation_rollover.nim
##
## DWCAS generation rollover smoke (impl plan Task 14a, design §8.3).
##
## Verifies that the `first` (sequence-counter) field of a
## Pair[uint64, T] wraps cleanly through uint64.high → 0 and that CAS
## continues to operate correctly across the wrap boundary. This is the
## ABA-prevention smoke design §8.3 calls for: the LCRQ pattern that
## motivates DWCAS uses `first` as a monotonically-bumped seq counter,
## and the only thing that defeats the counter's ABA defense is silent
## arithmetic on a non-wrapping integer.
##
## Wired into tests/test.nim — runs under arc / orc / atomicArc / refc.

import unittest2

import debra/atomics

type P = Pair[uint64, uint64]

suite "DWCAS generation rollover (uint64 wrap)":
  test "publish/claim cycles wrap uint64.high -> 0 cleanly (8 iterations)":
    var slot: Atomic[P]
    let startSeq = high(uint64) - 4'u64
    slot.store(Pair[uint64, uint64](first: startSeq, second: 0'u64))

    # 8 publish/claim cycles. The seq field starts at uint64.high - 4 and
    # crosses the uint64.high -> 0 wrap at iteration 5.
    for i in 0 ..< 8:
      var expected = slot.load()
      let nextSeq = expected.first + 1'u64
      let desired = Pair[uint64, uint64](first: nextSeq, second: i.uint64)
      check slot.compareExchangeStrong(expected, desired)

    let final = slot.load()
    # Nim's uint64 wraps on overflow. startSeq + 8 = uint64.high - 4 + 8
    # = uint64.high + 4 = (wrap) 3.
    check final.first == startSeq + 8'u64
    check final.second == 7'u64

  test "explicit wrap: store seq=uint64.high then CAS to seq=0":
    var slot: Atomic[P]
    slot.store(Pair[uint64, uint64](first: high(uint64), second: 0'u64))
    var expected = Pair[uint64, uint64](first: high(uint64), second: 0'u64)
    check slot.compareExchangeStrong(
      expected, Pair[uint64, uint64](first: 0'u64, second: 1'u64)
    )
    check slot.load() == Pair[uint64, uint64](first: 0'u64, second: 1'u64)

  test "CAS across wrap boundary uses post-wrap comparand":
    # After the wrap, a CAS whose `expected` matches the post-wrap value
    # must succeed; a CAS whose `expected` carries a stale pre-wrap value
    # must fail and update `expected` to the current post-wrap state.
    var slot: Atomic[P]
    slot.store(Pair[uint64, uint64](first: 0'u64, second: 42'u64))

    var stale = Pair[uint64, uint64](first: high(uint64), second: 42'u64)
    check (
      not slot.compareExchangeStrong(
        stale, Pair[uint64, uint64](first: 1'u64, second: 99'u64)
      )
    )
    # Failure must overwrite expected with the post-wrap value.
    check stale == Pair[uint64, uint64](first: 0'u64, second: 42'u64)

    # Now CAS with the post-wrap expected succeeds.
    var fresh = Pair[uint64, uint64](first: 0'u64, second: 42'u64)
    check slot.compareExchangeStrong(
      fresh, Pair[uint64, uint64](first: 1'u64, second: 100'u64)
    )
    check slot.load() == Pair[uint64, uint64](first: 1'u64, second: 100'u64)
