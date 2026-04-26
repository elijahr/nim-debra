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
