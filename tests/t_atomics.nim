# tests/t_atomics.nim
##
## Tests for debra/atomics: a custom atomics module that rejects ref T,
## enforces lock-free at compile time, and validates memory orders per op.

import unittest2

import debra/atomics

suite "MemoryOrder":
  test "ordinals match GCC __ATOMIC_*":
    check ord(moRelaxed) == 0
    check ord(moConsume) == 1
    check ord(moAcquire) == 2
    check ord(moRelease) == 3
    check ord(moAcquireRelease) == 4
    check ord(moSequentiallyConsistent) == 5

suite "load/store":
  test "int roundtrip with default order":
    var a: Atomic[int]
    a.store(42)
    check a.load() == 42

  test "int roundtrip with moRelaxed":
    var a: Atomic[int]
    a.store(7, moRelaxed)
    check a.load(moRelaxed) == 7

  test "int roundtrip with moRelease/moAcquire":
    var a: Atomic[int]
    a.store(99, moRelease)
    check a.load(moAcquire) == 99

  test "int8/16/32/64 roundtrips":
    var a8: Atomic[int8]
    a8.store(int8(-3))
    check a8.load() == int8(-3)
    var a16: Atomic[int16]
    a16.store(int16(-300))
    check a16.load() == int16(-300)
    var a32: Atomic[int32]
    a32.store(int32(-70_000))
    check a32.load() == int32(-70_000)
    var a64: Atomic[int64]
    a64.store(int64(1_000_000_000_000))
    check a64.load() == int64(1_000_000_000_000)

  test "uint8/16/32/64 roundtrips":
    var a8: Atomic[uint8]
    a8.store(uint8(250))
    check a8.load() == uint8(250)
    var a16: Atomic[uint16]
    a16.store(uint16(60_000))
    check a16.load() == uint16(60_000)
    var a32: Atomic[uint32]
    a32.store(uint32(4_000_000_000'u32))
    check a32.load() == uint32(4_000_000_000'u32)
    var a64: Atomic[uint64]
    a64.store(uint64(0xDEAD_BEEF_CAFE'u64))
    check a64.load() == uint64(0xDEAD_BEEF_CAFE'u64)

  test "bool roundtrip":
    var a: Atomic[bool]
    a.store(true)
    check a.load() == true
    a.store(false)
    check a.load() == false

  test "ptr roundtrip":
    var x: int = 5
    var a: Atomic[ptr int]
    a.store(addr x)
    check a.load() == addr x
    check a.load()[] == 5

  test "enum roundtrip":
    type Color = enum Red, Green, Blue
    var a: Atomic[Color]
    a.store(Green)
    check a.load() == Green
    a.store(Blue)
    check a.load() == Blue

suite "exchange":
  test "int exchange returns previous":
    var a: Atomic[int]
    a.store(10)
    check a.exchange(20) == 10
    check a.load() == 20

  test "ptr exchange":
    var x: int = 1
    var y: int = 2
    var a: Atomic[ptr int]
    a.store(addr x)
    let prev = a.exchange(addr y)
    check prev == addr x
    check a.load() == addr y

suite "fetch ops":
  test "fetchAdd returns old value":
    var a: Atomic[int]
    a.store(5)
    check a.fetchAdd(3) == 5
    check a.load() == 8

  test "fetchSub returns old value":
    var a: Atomic[int]
    a.store(10)
    check a.fetchSub(4) == 10
    check a.load() == 6

  test "fetchAnd / fetchOr / fetchXor":
    var a: Atomic[uint32]
    a.store(0b1100'u32)
    check a.fetchAnd(0b1010'u32) == 0b1100'u32
    check a.load() == 0b1000'u32
    a.store(0b0011'u32)
    check a.fetchOr(0b0100'u32) == 0b0011'u32
    check a.load() == 0b0111'u32
    a.store(0b1010'u32)
    check a.fetchXor(0b1100'u32) == 0b1010'u32
    check a.load() == 0b0110'u32

  test "fetchAdd works with all integer widths":
    var a8: Atomic[int8]
    a8.store(int8(10))
    check a8.fetchAdd(int8(5)) == int8(10)
    check a8.load() == int8(15)
    var a16: Atomic[uint16]
    a16.store(uint16(100))
    check a16.fetchAdd(uint16(200)) == uint16(100)
    check a16.load() == uint16(300)
    var a64: Atomic[uint64]
    a64.store(uint64(0xFF))
    check a64.fetchAdd(uint64(1)) == uint64(0xFF)
    check a64.load() == uint64(0x100)

suite "compareExchange":
  test "compareExchangeStrong success":
    var a: Atomic[int]
    a.store(5)
    var expected = 5
    check a.compareExchangeStrong(expected, 10) == true
    check expected == 5  # unchanged on success
    check a.load() == 10

  test "compareExchangeStrong failure overwrites expected":
    var a: Atomic[int]
    a.store(5)
    var expected = 99
    check a.compareExchangeStrong(expected, 10) == false
    check expected == 5  # overwritten with current value
    check a.load() == 5  # unchanged on failure

  test "compareExchangeWeak two-order success":
    var a: Atomic[int]
    a.store(5)
    var expected = 5
    # Weak may fail spuriously, retry until success or value differs.
    var ok = false
    for _ in 0..32:
      if a.compareExchangeWeak(expected, 10, moAcquireRelease, moAcquire):
        ok = true
        break
    check ok
    check a.load() == 10

  test "compareExchangeWeak failure overwrites expected":
    var a: Atomic[int]
    a.store(5)
    var expected = 99
    let res = a.compareExchangeWeak(expected, 10, moAcquireRelease, moAcquire)
    check res == false
    check expected == 5
    check a.load() == 5

  test "CAS loop idiom":
    # Standard pattern: read current, compute next, retry on weak failure.
    var a: Atomic[int]
    a.store(0)
    var current = a.load(moRelaxed)
    while not a.compareExchangeWeak(
        current, current * 2 + 1, moAcquireRelease, moAcquire):
      discard
    # 0 -> 0*2+1 = 1
    check a.load() == 1

  test "CAS on ptr":
    var x: int = 1
    var y: int = 2
    var a: Atomic[ptr int]
    a.store(addr x)
    var expected = addr x
    check a.compareExchangeStrong(expected, addr y) == true
    check a.load() == addr y

suite "fences":
  test "threadFence compiles and executes for each order":
    threadFence(moRelaxed)
    threadFence(moAcquire)
    threadFence(moRelease)
    threadFence(moAcquireRelease)
    threadFence(moSequentiallyConsistent)
    check true

  test "signalFence compiles and executes for each order":
    signalFence(moRelaxed)
    signalFence(moAcquire)
    signalFence(moRelease)
    signalFence(moAcquireRelease)
    signalFence(moSequentiallyConsistent)
    check true

suite "AtomicFlag":
  test "testAndSet on a fresh flag returns false then true":
    var flag: AtomicFlag
    check flag.testAndSet() == false
    check flag.testAndSet() == true

  test "clear resets the flag":
    var flag: AtomicFlag
    discard flag.testAndSet()
    flag.clear()
    check flag.testAndSet() == false

  test "clear with explicit memory order":
    var flag: AtomicFlag
    discard flag.testAndSet(moAcquire)
    flag.clear(moRelease)
    check flag.testAndSet(moAcquire) == false

suite "CacheLineBytes":
  test "is exported and a sensible value":
    when defined(powerpc):
      check CacheLineBytes == 128
    else:
      check CacheLineBytes == 64
