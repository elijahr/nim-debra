## Tests for 16-byte componentwise fetch ops on `Atomic[Pair[A, B]]`
## where `A, B: SomeInteger`. Closes the v0.10.0 "16-byte fetch* out of
## scope" constraint via CAS-loop lowerings on top of the existing
## `compareExchangeWeak` primitive.

import unittest2

import debra/atomics

template makePair[A, B](a: A, b: B): Pair[A, B] =
  Pair[A, B](first: a, second: b)

# Module-scope counter for the contention test. Module-scope (not
# `{.global.}` inside the test block) is required because `{.thread.}`
# worker procs cannot capture variables via closure.
var contentionCounter: Atomic[Pair[uint64, uint64]]

proc contentionWorker() {.thread.} =
  for _ in 0 ..< 10_000:
    discard fetchAdd(contentionCounter, makePair(1'u64, 3'u64))

suite "DWCAS fetchAdd round-trip":
  test "uint64+uint64 round-trip — both halves updated atomically":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(0'u64, 0'u64))
    let prev = fetchAdd(a, makePair(1'u64, 2'u64))
    check prev.first == 0'u64
    check prev.second == 0'u64
    let cur = load(a)
    check cur.first == 1'u64
    check cur.second == 2'u64

  test "uint64+uint64 second round trip accumulates":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(10'u64, 20'u64))
    discard fetchAdd(a, makePair(5'u64, 7'u64))
    let cur = load(a)
    check cur.first == 15'u64
    check cur.second == 27'u64

  test "uint64 half wraps modulo 2^64":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(high(uint64), 0'u64))
    discard fetchAdd(a, makePair(1'u64, 0'u64))
    let cur = load(a)
    check cur.first == 0'u64
    check cur.second == 0'u64

suite "DWCAS fetchSub round-trip":
  test "uint64+uint64 subtract":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(100'u64, 50'u64))
    let prev = fetchSub(a, makePair(7'u64, 9'u64))
    check prev.first == 100'u64
    check prev.second == 50'u64
    let cur = load(a)
    check cur.first == 93'u64
    check cur.second == 41'u64

suite "DWCAS fetchAnd round-trip":
  test "uint64+uint64 with bitmask":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(0xFFFF_FFFF_FFFF_FFFF'u64, 0xFFFF_FFFF_FFFF_FFFF'u64))
    let prev =
      fetchAnd(a, makePair(0x0F0F_0F0F_0F0F_0F0F'u64, 0xF0F0_F0F0_F0F0_F0F0'u64))
    check prev.first == 0xFFFF_FFFF_FFFF_FFFF'u64
    let cur = load(a)
    check cur.first == 0x0F0F_0F0F_0F0F_0F0F'u64
    check cur.second == 0xF0F0_F0F0_F0F0_F0F0'u64

suite "DWCAS fetchOr round-trip":
  test "uint64+uint64 with bitmask":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(0x0F0F_0F0F_0F0F_0F0F'u64, 0xF0F0_F0F0_F0F0_F0F0'u64))
    let prev =
      fetchOr(a, makePair(0xF0F0_F0F0_F0F0_F0F0'u64, 0x0F0F_0F0F_0F0F_0F0F'u64))
    check prev.first == 0x0F0F_0F0F_0F0F_0F0F'u64
    let cur = load(a)
    check cur.first == 0xFFFF_FFFF_FFFF_FFFF'u64
    check cur.second == 0xFFFF_FFFF_FFFF_FFFF'u64

suite "DWCAS fetchXor round-trip":
  test "uint64+uint64 with bitmask":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(0xFFFF_0000_FFFF_0000'u64, 0x0000_FFFF_0000_FFFF'u64))
    let prev =
      fetchXor(a, makePair(0xFFFF_FFFF_FFFF_FFFF'u64, 0xFFFF_FFFF_FFFF_FFFF'u64))
    check prev.first == 0xFFFF_0000_FFFF_0000'u64
    let cur = load(a)
    check cur.first == 0x0000_FFFF_0000_FFFF'u64
    check cur.second == 0xFFFF_0000_FFFF_0000'u64

suite "DWCAS fetchAdd contention":
  # N threads each performing K iterations of fetchAdd(1, 1) → the final
  # pair must equal (N*K, N*K). This catches half-state visibility bugs
  # where the two integer halves are NOT updated as a single 128-bit
  # atomic transaction.
  test "8 threads × 10_000 iters each — both halves sum correctly":
    const N = 8
    const K = 10_000
    store(contentionCounter, makePair(0'u64, 0'u64))

    var threads: array[N, Thread[void]]
    for i in 0 ..< N:
      createThread(threads[i], contentionWorker)
    joinThreads(threads)

    let cur = load(contentionCounter)
    check cur.first == uint64(N * K)
    check cur.second == uint64(N * K * 3)

suite "DWCAS fetchAdd order overloads":
  test "default-order form (seq_cst)":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(0'u64, 0'u64))
    discard fetchAdd(a, makePair(1'u64, 1'u64))
    let cur = load(a)
    check cur.first == 1'u64
    check cur.second == 1'u64

  test "explicit moSequentiallyConsistent":
    var a: Atomic[Pair[uint64, uint64]]
    store(a, makePair(0'u64, 0'u64))
    discard fetchAdd(a, makePair(2'u64, 3'u64), moSequentiallyConsistent)
    let cur = load(a)
    check cur.first == 2'u64
    check cur.second == 3'u64
