# tests/t_atomics.nim
##
## Tests for debra/atomics: a custom atomics module that rejects ref T,
## enforces lock-free at compile time, and validates memory orders per op.

import std/math

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
    type Color = enum
      Red
      Green
      Blue

    var a: Atomic[Color]
    a.store(Green)
    check a.load() == Green
    a.store(Blue)
    check a.load() == Blue

  test "pointer (untyped) roundtrip":
    var x: int = 9
    var a: Atomic[pointer]
    a.store(cast[pointer](addr x))
    check a.load() == cast[pointer](addr x)

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

  test "fetchSub works with all integer widths":
    # Exercises the MSVC 1-byte fetchSub path which negates through `int8`
    # because `cchar` is Nim's `char` and unary `-` is undefined on it.
    var a8: Atomic[int8]
    a8.store(int8(10))
    check a8.fetchSub(int8(3)) == int8(10)
    check a8.load() == int8(7)
    var au8: Atomic[uint8]
    au8.store(uint8(200))
    check au8.fetchSub(uint8(50)) == uint8(200)
    check au8.load() == uint8(150)
    var a16: Atomic[int16]
    a16.store(int16(1000))
    check a16.fetchSub(int16(250)) == int16(1000)
    check a16.load() == int16(750)
    var a32: Atomic[uint32]
    a32.store(uint32(0x1_0000))
    check a32.fetchSub(uint32(1)) == uint32(0x1_0000)
    check a32.load() == uint32(0xFFFF)
    var a64: Atomic[int64]
    a64.store(int64(0x1_0000_0000))
    check a64.fetchSub(int64(1)) == int64(0x1_0000_0000)
    check a64.load() == int64(0xFFFF_FFFF)

  test "fetchSub handles signed-low boundary without UB":
    # Regression for MSVC fetchSub: negation must be computed in the
    # unsigned domain so values whose signed reinterpretation is `.low`
    # do not trigger C signed-overflow UB. Exercise all 4 widths with
    # the boundary bit pattern (high bit set), via the unsigned types
    # so the literal fits without conversion errors on signed `.low`.
    var au8: Atomic[uint8]
    au8.store(0'u8)
    # 128'u8 reinterpreted as int8 is -128 (int8.low); naive `-cast[int8](v)`
    # would overflow. Correct behavior: 0 - 128 wraps to 128 in uint8.
    check au8.fetchSub(128'u8) == 0'u8
    check au8.load() == (0'u8 - 128'u8)
    var au16: Atomic[uint16]
    au16.store(0'u16)
    check au16.fetchSub(0x8000'u16) == 0'u16
    check au16.load() == (0'u16 - 0x8000'u16)
    var au32: Atomic[uint32]
    au32.store(0'u32)
    check au32.fetchSub(0x8000_0000'u32) == 0'u32
    check au32.load() == (0'u32 - 0x8000_0000'u32)
    var au64: Atomic[uint64]
    au64.store(0'u64)
    check au64.fetchSub(0x8000_0000_0000_0000'u64) == 0'u64
    check au64.load() == (0'u64 - 0x8000_0000_0000_0000'u64)

suite "compareExchange":
  test "compareExchangeStrong success":
    var a: Atomic[int]
    a.store(5)
    var expected = 5
    check a.compareExchangeStrong(expected, 10) == true
    check expected == 5 # unchanged on success
    check a.load() == 10

  test "compareExchangeStrong failure overwrites expected":
    var a: Atomic[int]
    a.store(5)
    var expected = 99
    check a.compareExchangeStrong(expected, 10) == false
    check expected == 5 # overwritten with current value
    check a.load() == 5 # unchanged on failure

  test "compareExchangeWeak two-order success":
    var a: Atomic[int]
    a.store(5)
    var expected = 5
    # Weak may fail spuriously, retry until success or value differs.
    var ok = false
    for _ in 0 .. 32:
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
      current, current * 2 + 1, moAcquireRelease, moAcquire
    )
    :
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

  test "compareExchangeStrong single-order form with moAcquire":
    # The single-order overload derives failure order from success
    # (drops the release component). success=moAcquire -> failure=moAcquire.
    # Without the overload this call would bind failure to the default
    # moSequentiallyConsistent and fail validCasFailureOrder.
    var a: Atomic[int]
    a.store(5)
    var expected = 5
    check a.compareExchangeStrong(expected, 10, moAcquire) == true
    check a.load() == 10

  test "compareExchangeStrong single-order form with moRelease":
    # success=moRelease -> failure=moRelaxed (C11 derivation).
    var a: Atomic[int]
    a.store(7)
    var expected = 7
    check a.compareExchangeStrong(expected, 13, moRelease) == true
    check a.load() == 13

  test "compareExchangeWeak single-order form with moAcquireRelease":
    # success=moAcquireRelease -> failure=moAcquire.
    var a: Atomic[int]
    a.store(5)
    var expected = 5
    var ok = false
    for _ in 0 .. 32:
      if a.compareExchangeWeak(expected, 10, moAcquireRelease):
        ok = true
        break
    check ok
    check a.load() == 10

  test "single-order CAS failure overwrites expected":
    var a: Atomic[int]
    a.store(5)
    var expected = 99
    check a.compareExchangeStrong(expected, 10, moAcquire) == false
    check expected == 5
    check a.load() == 5

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

suite "static rejection":
  test "Atomic[ref T] does not compile":
    # The error fires at instantiation; `compiles` swallows it.
    check not compiles(
      block:
        var a: Atomic[ref string]
        a.store(nil)
    )

  test "Atomic[POD object] compiles and round-trips":
    # T must satisfy `supportsCopyMem` (no GC-managed fields, recursively)
    # AND pass the C-level lock-free check. POD object types up to the
    # platform's lock-free word size with natural alignment >= sizeof
    # are admitted. Wrappers around `Pthread` (e.g. ThreadId) and other
    # small PODs go through this path.
    type Pod = object
      handle: int # int is naturally word-aligned, mirrors ThreadId(handle: Pthread)

    var a: Atomic[Pod]
    let v = Pod(handle: 0xDEADBEEF)
    a.store(v)
    let r = a.load()
    check r.handle == 0xDEADBEEF

  test "Atomic[distinct uint64] compiles and round-trips":
    type Tag = distinct uint64
    proc `==`(a, b: Tag): bool {.borrow.}
    var a: Atomic[Tag]
    a.store(Tag(0x1234_5678'u64))
    check a.load() == Tag(0x1234_5678'u64)

  test "Atomic[object containing ref field] does not compile":
    # supportsCopyMem rejects this even though the outer type is an
    # object: any GC-managed field anywhere in the type makes it
    # unsafe to copy bytewise.
    check not compiles(
      block:
        type WithRef = object
          r: ref int

        var a: Atomic[WithRef]
        discard a.load()
    )

  test "Atomic[seq[T]] does not compile (not a Trivial type)":
    # Constraints fire at op site; trying to load forces it.
    check not compiles(
      block:
        var a: Atomic[seq[int]]
        discard a.load()
    )

  test "Atomic[string] does not compile (not a Trivial type)":
    check not compiles(
      block:
        var a: Atomic[string]
        discard a.load()
    )

  test "store with moAcquire does not compile":
    check not compiles(
      block:
        var a: Atomic[int]
        a.store(1, moAcquire)
    )

  test "store with moAcquireRelease does not compile":
    check not compiles(
      block:
        var a: Atomic[int]
        a.store(1, moAcquireRelease)
    )

  test "load with moRelease does not compile":
    check not compiles(
      block:
        var a: Atomic[int]
        discard a.load(moRelease)
    )

  test "load with moAcquireRelease does not compile":
    check not compiles(
      block:
        var a: Atomic[int]
        discard a.load(moAcquireRelease)
    )

  test "compareExchange failure stronger than success does not compile":
    # Real ord violation: success=moAcquire (2), failure=moSeqCst (5).
    check not compiles(
      block:
        var a: Atomic[int]
        var expected = 0
        discard
          a.compareExchangeStrong(expected, 1, moAcquire, moSequentiallyConsistent)
    )

  test "compareExchange success=moRelease, failure=moAcquire does not compile":
    # C11 §7.17.7.4: moRelease has no load-acquire on the success path,
    # so the failure load cannot acquire either. The prior raw
    # `ord(failure) <= ord(success)` check would have allowed this
    # (moAcquire=2 <= moRelease=3) — the stricter lattice check forbids it.
    check not compiles(
      block:
        var a: Atomic[int]
        var expected = 0
        discard a.compareExchangeStrong(expected, 1, moRelease, moAcquire)
    )

  test "compareExchange success=moRelease, failure=moConsume does not compile":
    check not compiles(
      block:
        var a: Atomic[int]
        var expected = 0
        discard a.compareExchangeStrong(expected, 1, moRelease, moConsume)
    )

  test "compareExchange failure=moRelease does not compile":
    check not compiles(
      block:
        var a: Atomic[int]
        var expected = 0
        discard
          a.compareExchangeStrong(expected, 1, moSequentiallyConsistent, moRelease)
    )

  test "compareExchange failure=moAcquireRelease does not compile":
    check not compiles(
      block:
        var a: Atomic[int]
        var expected = 0
        discard a.compareExchangeStrong(
          expected, 1, moSequentiallyConsistent, moAcquireRelease
        )
    )

  test "valid store orders compile":
    check compiles(
      block:
        var a: Atomic[int]
        a.store(1, moRelaxed)
        a.store(1, moRelease)
        a.store(1, moSequentiallyConsistent)
    )

  test "valid load orders compile":
    check compiles(
      block:
        var a: Atomic[int]
        discard a.load(moRelaxed)
        discard a.load(moConsume)
        discard a.load(moAcquire)
        discard a.load(moSequentiallyConsistent)
    )

  # Note on non-lock-free coverage: on 64-bit macOS/Linux every
  # primitive supported by `assertAtomCompat` (size <= 8) is
  # lock-free, so a positive test for the
  # `-d:debraAllowNonLockFreeAtomics` opt-out cannot be expressed
  # without a 32-bit target or a hostile build flag. The flag itself
  # is parsed unconditionally; failing builds on non-lock-free
  # primitives is exercised by the 32-bit CI lane in Phase D.

suite "float load/store":
  test "float32 load/store roundtrip with sentinel values":
    var a: Atomic[float32]
    # Zero
    a.store(0.0'f32)
    check a.load() == 0.0'f32
    # Positive integer-valued float
    a.store(1.0'f32)
    check a.load() == 1.0'f32
    # Negative
    a.store(-1.0'f32)
    check a.load() == -1.0'f32
    # Approximate pi
    a.store(3.1415927'f32)
    check a.load() == 3.1415927'f32
    # Negative zero: bit-distinct from +0.0 but `==` returns true.
    # Verify both: `==` is true AND the bit pattern is preserved through
    # the bitcast roundtrip.
    a.store(-0.0'f32)
    check a.load() == -0.0'f32
    check cast[uint32](a.load()) == cast[uint32](-0.0'f32)
    check cast[uint32](a.load()) != cast[uint32](0.0'f32)
    # Smallest positive subnormal float32 (~1.4e-45). Subnormals have
    # special bit layouts; verify bitcast preserves them exactly.
    let subnormal = cast[float32](1'u32)
    a.store(subnormal)
    check cast[uint32](a.load()) == 1'u32

  test "float32 NaN load/store preserves bit pattern":
    # `==` on NaN returns false, so we can't compare with `==`. The
    # bitcast roundtrip must preserve the exact NaN bit pattern.
    var a: Atomic[float32]
    let nanBits: uint32 = 0x7FC0_0000'u32 # canonical quiet NaN
    let nanVal = cast[float32](nanBits)
    a.store(nanVal)
    check cast[uint32](a.load()) == nanBits

  test "float64 load/store roundtrip with sentinel values":
    var a: Atomic[float64]
    a.store(0.0'f64)
    check a.load() == 0.0'f64
    a.store(1.0'f64)
    check a.load() == 1.0'f64
    a.store(-1.0'f64)
    check a.load() == -1.0'f64
    a.store(3.141592653589793'f64)
    check a.load() == 3.141592653589793'f64
    # Negative zero bit preservation.
    a.store(-0.0'f64)
    check a.load() == -0.0'f64
    check cast[uint64](a.load()) == cast[uint64](-0.0'f64)
    check cast[uint64](a.load()) != cast[uint64](0.0'f64)
    # Smallest positive subnormal float64.
    let subnormal = cast[float64](1'u64)
    a.store(subnormal)
    check cast[uint64](a.load()) == 1'u64

  test "float64 NaN load/store preserves bit pattern":
    var a: Atomic[float64]
    let nanBits: uint64 = 0x7FF8_0000_0000_0000'u64 # canonical quiet NaN
    let nanVal = cast[float64](nanBits)
    a.store(nanVal)
    check cast[uint64](a.load()) == nanBits

  test "float load/store with explicit memory orders":
    var a32: Atomic[float32]
    a32.store(2.5'f32, moRelease)
    check a32.load(moAcquire) == 2.5'f32
    a32.store(7.0'f32, moRelaxed)
    check a32.load(moRelaxed) == 7.0'f32
    var a64: Atomic[float64]
    a64.store(2.5'f64, moRelease)
    check a64.load(moAcquire) == 2.5'f64

suite "float exchange":
  test "float32 exchange returns previous value":
    var a: Atomic[float32]
    a.store(10.5'f32)
    check a.exchange(20.25'f32) == 10.5'f32
    check a.load() == 20.25'f32

  test "float64 exchange returns previous value":
    var a: Atomic[float64]
    a.store(10.5'f64)
    check a.exchange(20.25'f64) == 10.5'f64
    check a.load() == 20.25'f64

  test "float exchange preserves -0.0 bit pattern":
    # exchange must use bit-level transfer so -0.0 round-trips bit-exactly.
    var a: Atomic[float32]
    a.store(1.0'f32)
    let prev = a.exchange(-0.0'f32)
    check prev == 1.0'f32
    check cast[uint32](a.load()) == cast[uint32](-0.0'f32)

suite "float compareExchange":
  test "float32 compareExchangeStrong success":
    var a: Atomic[float32]
    a.store(1.5'f32)
    var expected = 1.5'f32
    check a.compareExchangeStrong(expected, 2.5'f32) == true
    check expected == 1.5'f32 # unchanged on success
    check a.load() == 2.5'f32

  test "float32 compareExchangeStrong failure overwrites expected":
    var a: Atomic[float32]
    a.store(1.5'f32)
    var expected = 9.0'f32
    check a.compareExchangeStrong(expected, 2.5'f32) == false
    check expected == 1.5'f32 # overwritten with current value
    check a.load() == 1.5'f32 # unchanged on failure

  test "float64 compareExchangeStrong success":
    var a: Atomic[float64]
    a.store(1.5'f64)
    var expected = 1.5'f64
    check a.compareExchangeStrong(expected, 2.5'f64) == true
    check expected == 1.5'f64
    check a.load() == 2.5'f64

  test "float64 compareExchangeStrong failure overwrites expected":
    var a: Atomic[float64]
    a.store(1.5'f64)
    var expected = 9.0'f64
    check a.compareExchangeStrong(expected, 2.5'f64) == false
    check expected == 1.5'f64
    check a.load() == 1.5'f64

  test "float compareExchangeWeak two-order success":
    var a: Atomic[float32]
    a.store(1.5'f32)
    var expected = 1.5'f32
    var ok = false
    for _ in 0 .. 32:
      if a.compareExchangeWeak(expected, 2.5'f32, moAcquireRelease, moAcquire):
        ok = true
        break
    check ok
    check a.load() == 2.5'f32

  test "float CAS is bit-equality: distinct NaN payloads do not match":
    # CAS routes through the integer specialization, so equality is
    # bit-equality. Two distinct NaN bit patterns will NOT compare
    # equal even though `==` on floats also returns false for NaNs.
    # The current value's bits must match `expected`'s bits exactly.
    var a: Atomic[float32]
    let nanA = cast[float32](0x7FC0_0000'u32) # quiet NaN, payload 0
    let nanB = cast[float32](0x7FC0_0001'u32) # quiet NaN, payload 1
    a.store(nanA)
    var expected = nanB # different bit pattern
    let ok = a.compareExchangeStrong(expected, 0.0'f32)
    check ok == false
    # On failure, expected is overwritten with the actual current bits.
    check cast[uint32](expected) == cast[uint32](nanA)
    # Storage unchanged.
    check cast[uint32](a.load()) == cast[uint32](nanA)

  test "float CAS is bit-equality: same NaN bit pattern matches":
    # Counterpart: when the bit patterns DO match, CAS succeeds even
    # though `==` on NaNs is false. This is the intended semantics:
    # CAS sees raw bits, not float equality.
    var a: Atomic[float32]
    let nanBits: uint32 = 0x7FC0_0000'u32
    let nanVal = cast[float32](nanBits)
    a.store(nanVal)
    var expected = nanVal # exact same bits
    let ok = a.compareExchangeStrong(expected, 0.0'f32)
    check ok == true
    check a.load() == 0.0'f32

  test "float CAS is bit-equality: +0.0 does not match -0.0":
    # `0.0 == -0.0` is true semantically, but their bit patterns
    # differ. CAS uses bit-equality, so a CAS expecting +0.0 against a
    # storage holding -0.0 must FAIL. Document this behavior.
    var a: Atomic[float32]
    a.store(-0.0'f32)
    var expected = 0.0'f32 # different bits from -0.0
    let ok = a.compareExchangeStrong(expected, 1.0'f32)
    check ok == false
    # On failure, expected is overwritten with the current bits (-0.0).
    check cast[uint32](expected) == cast[uint32](-0.0'f32)
    check cast[uint32](a.load()) == cast[uint32](-0.0'f32)

suite "float fetchAdd":
  test "float32 fetchAdd returns old value and accumulates":
    var a: Atomic[float32]
    a.store(0.0'f32)
    check a.fetchAdd(1.5'f32) == 0.0'f32
    check a.load() == 1.5'f32
    check a.fetchAdd(0.25'f32) == 1.5'f32
    check a.load() == 1.75'f32

  test "float32 fetchAdd with negative delta":
    var a: Atomic[float32]
    a.store(5.0'f32)
    check a.fetchAdd(-0.5'f32) == 5.0'f32
    check a.load() == 4.5'f32
    check a.fetchAdd(-4.5'f32) == 4.5'f32
    check a.load() == 0.0'f32

  test "float64 fetchAdd returns old value and accumulates":
    var a: Atomic[float64]
    a.store(0.0'f64)
    check a.fetchAdd(1.5'f64) == 0.0'f64
    check a.load() == 1.5'f64
    check a.fetchAdd(0.25'f64) == 1.5'f64
    check a.load() == 1.75'f64

  test "float64 fetchAdd with mixed signs":
    var a: Atomic[float64]
    a.store(10.0'f64)
    check a.fetchAdd(-3.0'f64) == 10.0'f64
    check a.fetchAdd(2.5'f64) == 7.0'f64
    check a.fetchAdd(-9.5'f64) == 9.5'f64
    check a.load() == 0.0'f64

  test "float fetchAdd with explicit memory order":
    var a: Atomic[float32]
    a.store(1.0'f32)
    check a.fetchAdd(2.0'f32, moAcquireRelease) == 1.0'f32
    check a.load() == 3.0'f32

  test "float32 fetchAdd overflow produces +Inf":
    # `fetchAdd` performs an IEEE-754 add; overflowing the format
    # range produces +Inf. Document this as part of the FPU-state
    # contract: the new stored value is whatever the FPU computes.
    let maxF32 = cast[float32](0x7F7F_FFFF'u32) # largest finite float32
    var a: Atomic[float32]
    a.store(maxF32)
    let old = a.fetchAdd(maxF32)
    # Old value is bit-exact (relaxed-load contract): the pre-RMW
    # storage bits round-trip into the return value.
    check cast[uint32](old) == cast[uint32](maxF32)
    # New stored value overflowed to +Inf.
    check classify(a.load()) == fcInf
    check a.load() > 0.0'f32

  test "float64 fetchAdd overflow produces +Inf":
    let maxF64 = cast[float64](0x7FEF_FFFF_FFFF_FFFF'u64)
    var a: Atomic[float64]
    a.store(maxF64)
    let old = a.fetchAdd(maxF64)
    check cast[uint64](old) == cast[uint64](maxF64)
    check classify(a.load()) == fcInf
    check a.load() > 0.0'f64

  test "float32 fetchAdd of NaN: old value is bit-exact, new value is some NaN":
    # Locks in the FPU-state contract for NaN inputs:
    #   * The OLD value returned by fetchAdd is bit-exact (it comes
    #     from a relaxed load before the add) - the original NaN
    #     bit pattern is preserved in the return value.
    #   * The NEW stored value is `NaN + 1.0`, which IEEE-754 says
    #     is some NaN with implementation-defined payload. We do
    #     NOT promise the payload is preserved across the add.
    let nanBits: uint32 = 0x7FC0_0042'u32 # quiet NaN, payload 0x42
    let nanVal = cast[float32](nanBits)
    var a: Atomic[float32]
    a.store(nanVal)
    let old = a.fetchAdd(1.0'f32)
    # Old value: bit-exact match to the original NaN.
    check cast[uint32](old) == nanBits
    # New stored value: some NaN (any bit pattern). Do NOT assert on
    # the payload - that's implementation-defined.
    check classify(a.load()) == fcNan

  test "float64 fetchAdd of NaN: old value is bit-exact, new value is some NaN":
    let nanBits: uint64 = 0x7FF8_0000_0000_0042'u64
    let nanVal = cast[float64](nanBits)
    var a: Atomic[float64]
    a.store(nanVal)
    let old = a.fetchAdd(1.0'f64)
    check cast[uint64](old) == nanBits
    check classify(a.load()) == fcNan

  test "float64 fetchAdd of +Inf + (-Inf) yields NaN":
    # IEEE-754: `+Inf + -Inf` is NaN (invalid operation). The old
    # value returned must be the original +Inf bit pattern.
    var a: Atomic[float64]
    a.store(Inf)
    let old = a.fetchAdd(NegInf)
    # Old is bit-exact: the +Inf we stored.
    check cast[uint64](old) == cast[uint64](float64(Inf))
    check classify(old) == fcInf
    check old > 0.0'f64
    # New stored value: NaN (any pattern).
    check classify(a.load()) == fcNan

  test "float32 fetchAdd of +Inf + (-Inf) yields NaN":
    var a: Atomic[float32]
    a.store(float32(Inf))
    let old = a.fetchAdd(float32(NegInf))
    check cast[uint32](old) == cast[uint32](float32(Inf))
    check classify(old) == fcInf
    check old > 0.0'f32
    check classify(a.load()) == fcNan

when compileOption("threads"):
  suite "multi-threaded smoke":
    test "4 threads each fetchAdd 1000 increments share a counter":
      var counter: Atomic[int]
      counter.store(0)
      const NumThreads = 4
      const Increments = 1000
      var threads: array[NumThreads, Thread[ptr Atomic[int]]]

      proc worker(c: ptr Atomic[int]) {.thread.} =
        for _ in 0 ..< Increments:
          discard c[].fetchAdd(1, moAcquireRelease)

      for i in 0 ..< NumThreads:
        createThread(threads[i], worker, addr counter)
      for i in 0 ..< NumThreads:
        joinThread(threads[i])

      check counter.load() == NumThreads * Increments

    test "4 threads each fetchAdd 1.0 on a shared float64 counter":
      # Float fetchAdd is implemented via CAS-loop, not a hardware atomic
      # add, so this test exercises the loop's correctness under
      # contention. With 4 threads each adding 1.0 a thousand times to a
      # float64, the result must be exactly 4000.0 because float64 can
      # represent integers up to 2^53 without loss; every intermediate
      # sum is also representable exactly.
      var counter: Atomic[float64]
      counter.store(0.0'f64)
      const NumThreads = 4
      const Increments = 1000
      var threads: array[NumThreads, Thread[ptr Atomic[float64]]]

      proc worker(c: ptr Atomic[float64]) {.thread.} =
        for _ in 0 ..< Increments:
          discard c[].fetchAdd(1.0'f64, moAcquireRelease)

      for i in 0 ..< NumThreads:
        createThread(threads[i], worker, addr counter)
      for i in 0 ..< NumThreads:
        joinThread(threads[i])

      check counter.load() == float64(NumThreads * Increments)

# ---------------------------------------------------------------------------
# DWCAS (v0.10.0): Pair[A, B] type shape
# ---------------------------------------------------------------------------

suite "Pair type shape":
  test "Pair[uint64, uint64] is 16 bytes and 16-byte aligned":
    static:
      doAssert sizeof(Pair[uint64, uint64]) == 16
      doAssert alignof(Pair[uint64, uint64]) == 16

  test "Pair[uint64, ptr int] is 16 bytes and 16-byte aligned":
    static:
      doAssert sizeof(Pair[uint64, ptr int]) == 16
      doAssert alignof(Pair[uint64, ptr int]) == 16

  test "Pair stores and reads back first/second":
    let p = Pair[uint64, uint64](first: 7'u64, second: 9'u64)
    check p.first == 7'u64
    check p.second == 9'u64

suite "DWCAS gate 1 (pointer size)":
  test "host is 64-bit and module exports a size-16 specialization block":
    # Smoke: on a 64-bit target this compiles. Gate 1 itself (the
    # `{.error:.}` else-arm) is a design-time wrapper verified by code
    # review + Task 33 audit script. A runtime 32-bit cross-compile
    # should_fail is deferred to v0.10.1 (see §13 "Known limitations:
    # gate-1 32-bit verification").
    static:
      doAssert sizeof(pointer) == 8
    # Positive smoke for enforceDwcasConstraints: must compile cleanly
    # for valid Pair shapes.
    enforceDwcasConstraints(uint64, uint64)
    enforceDwcasConstraints(uint64, ptr int)

suite "DWCAS load (round-trip seed)":
  test "load on freshly-stored Atomic[Pair[uint64, uint64]] returns same bits":
    var a: Atomic[Pair[uint64, uint64]]
    # Store via direct memcpy seeding (load-only test; store path arrives in task 8).
    var seed = Pair[uint64, uint64](first: 7'u64, second: 9'u64)
    copyMem(addr a, addr seed, 16)
    let r = a.load()
    check r.first == 7'u64
    check r.second == 9'u64

suite "DWCAS store/load round-trip":
  test "store then load returns same Pair":
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 11'u64, second: 13'u64))
    let r = a.load()
    check r.first == 11'u64
    check r.second == 13'u64

suite "DWCAS exchange":
  test "exchange returns old, installs new":
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
    let old = a.exchange(Pair[uint64, uint64](first: 3'u64, second: 4'u64))
    check old.first == 1'u64
    check old.second == 2'u64
    let cur = a.load()
    check cur.first == 3'u64
    check cur.second == 4'u64

suite "DWCAS compareExchangeStrong":
  test "success: expected matches, returns true, slot updated, expected unchanged":
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
    var expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
    let ok = a.compareExchangeStrong(
      expected, Pair[uint64, uint64](first: 5'u64, second: 6'u64)
    )
    check ok
    check expected.first == 1'u64
    check expected.second == 2'u64
    let cur = a.load()
    check cur.first == 5'u64
    check cur.second == 6'u64

  test "failure: expected mismatch, returns false, slot unchanged, expected updated":
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
    var expected = Pair[uint64, uint64](first: 99'u64, second: 99'u64)
    let ok = a.compareExchangeStrong(
      expected, Pair[uint64, uint64](first: 5'u64, second: 6'u64)
    )
    check not ok
    check expected.first == 1'u64
    check expected.second == 2'u64
    let cur = a.load()
    check cur.first == 1'u64
    check cur.second == 2'u64

  test "single-order overload derives failure order from success":
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 7'u64, second: 8'u64))
    var expected = Pair[uint64, uint64](first: 7'u64, second: 8'u64)
    let ok = a.compareExchangeStrong(
      expected,
      Pair[uint64, uint64](first: 9'u64, second: 10'u64),
      moSequentiallyConsistent,
    )
    check ok
    let cur = a.load()
    check cur.first == 9'u64
    check cur.second == 10'u64

  test "five-arg overload with explicit success+failure orders":
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 21'u64, second: 22'u64))
    var expected = Pair[uint64, uint64](first: 21'u64, second: 22'u64)
    let ok = a.compareExchangeStrong(
      expected,
      Pair[uint64, uint64](first: 23'u64, second: 24'u64),
      moSequentiallyConsistent,
      moSequentiallyConsistent,
    )
    check ok
    let cur = a.load()
    check cur.first == 23'u64
    check cur.second == 24'u64

suite "DWCAS compareExchangeWeak":
  test "success: expected matches, returns true, slot updated":
    # Note: weak CAS can spuriously fail on aarch64 LL/SC even under
    # no contention; retry loop guards against the spurious-failure case.
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
    var expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
    var ok = false
    for _ in 0 ..< 64:
      expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
      ok = a.compareExchangeWeak(
        expected, Pair[uint64, uint64](first: 5'u64, second: 6'u64)
      )
      if ok:
        break
      # If spurious-failure path, the slot should still hold (1, 2).
      check a.load().first == 1'u64
    check ok
    let cur = a.load()
    check cur.first == 5'u64
    check cur.second == 6'u64

  test "failure: expected mismatch, returns false, expected updated":
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
    var expected = Pair[uint64, uint64](first: 99'u64, second: 99'u64)
    let ok =
      a.compareExchangeWeak(expected, Pair[uint64, uint64](first: 5'u64, second: 6'u64))
    check not ok
    check expected.first == 1'u64
    check expected.second == 2'u64

suite "DWCAS compareExchange aliases":
  test "compareExchange (3-arg default-order) routes to Strong":
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
    var expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
    let ok =
      a.compareExchange(expected, Pair[uint64, uint64](first: 7'u64, second: 8'u64))
    check ok
    let cur = a.load()
    check cur.first == 7'u64
    check cur.second == 8'u64

  test "compareExchange (4-arg single-order) routes to Strong":
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
    var expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
    let ok = a.compareExchange(
      expected,
      Pair[uint64, uint64](first: 7'u64, second: 8'u64),
      moSequentiallyConsistent,
    )
    check ok

  test "compareExchange (5-arg explicit-orders) routes to Strong":
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
    var expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
    let ok = a.compareExchange(
      expected,
      Pair[uint64, uint64](first: 7'u64, second: 8'u64),
      moSequentiallyConsistent,
      moSequentiallyConsistent,
    )
    check ok

suite "DWCAS per-callsite warning silencer":
  test "dwcasOrderRelaxedCAS suppresses moSeqCst-upgrade warning":
    # Compile-only check: this fixture intentionally passes moRelease/moRelaxed
    # to a CAS. Without the wrapper, a {.warning.} fires; with the wrapper,
    # it is silenced. Real verification of suppression is the CI compile-output
    # grep test (Task 19); this suite confirms the wrapper exists and compiles.
    var a: Atomic[Pair[uint64, uint64]]
    a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
    var expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
    dwcasOrderRelaxedCAS:
      discard a.compareExchangeStrong(
        expected,
        Pair[uint64, uint64](first: 3'u64, second: 4'u64),
        moRelease,
        moRelaxed,
      )
    # No runtime check: the real verification is the CI compile-output grep
    # (Task 19) that confirms the moSeqCst-upgrade warning is silenced. This
    # test block exists so the dwcasOrderRelaxedCAS wrapper is exercised at
    # compile time; reaching this point IS the smoke test.
