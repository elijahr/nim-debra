## debra/atomics
##
## Custom atomics for nim-debra (and lockfreequeues).
##
## Goals over std/atomics:
##   * Reject `Atomic[ref T]` at compile time (no silent spinlock).
##   * Require `Atomic[T]` to be lock-free at compile time.
##   * Validate `MemoryOrder` per op at compile time.
##   * Statically assert `alignof(Atomic[T]) >= sizeof(T)` so a target
##     where `T`'s natural alignment is insufficient (e.g. `uint64` on
##     some 32-bit ABIs) fails to compile rather than silently downgrading
##     to a non-lock-free split-lock object. The assert is the safety
##     boundary; we cannot force alignment higher than the type's natural
##     alignment from generic code (see `Atomic[T]` doc), so we trap the
##     mismatch instead.
##
## Design doc: docs/design/2026-04-25-custom-atomics.md
##
## User guide: see docs/guide/atomics.md for a side-by-side comparison
## with std/atomics, the DWCAS surface overview, memory-order policy,
## cross-compiler/arch compatibility matrix, and an LCRQ-style worked
## example.
##
## Backend strategy: wrap GCC/Clang `__atomic_*_n` builtins (already
## bound by Nim's `std/sysatomics` module). MSVC fallback is a future
## item; this module currently requires gcc, clang, llvm_gcc, or the
## Nintendo Switch toolchain.
##
## DWCAS (16-byte) emit logic adapted from atomic128
## (https://github.com/patternnoster/atomic128) by patternnoster,
## MIT licensed. See atomic128_ref.hpp for the C++ reference
## implementation that documents the GCC __sync vs __atomic
## footgun this code works around. Pinned upstream commit:
## d45ba3d348a9620a25552f9cf50dc7ccef05ef90.
## See THIRD_PARTY_LICENSES.md for the verbatim MIT text.

import std/sysatomics
import std/typetraits

when not (
  defined(gcc) or defined(llvm_gcc) or defined(clang) or defined(nintendoswitch)
):
  {.
    error:
      "debra/atomics currently requires gcc, clang, llvm_gcc, or " &
      "nintendoswitch (the GCC __atomic_* builtin family). MSVC " &
      "fallback is a future item."
  .}

# ---------------------------------------------------------------------------
# MemoryOrder
# ---------------------------------------------------------------------------

type MemoryOrder* = enum
  ## Specifies how non-atomic operations can be reordered around atomic
  ## operations. Ordinals match GCC's `__ATOMIC_*` so `ord(order)` is
  ## passed directly to the builtins.
  moRelaxed ## No ordering constraints.
  moConsume ## Accepted, mapped to moAcquire (mirrors std).
  moAcquire ## No reordering of subsequent loads/stores before.
  moRelease ## No reordering of preceding loads/stores after.
  moAcquireRelease ## Both acquire and release on RMW.
  moSequentiallyConsistent ## Single total order across all SC ops.

template toAtomMemModel(o: MemoryOrder): AtomMemModel =
  cast[AtomMemModel](cint(ord(o)))

# ---------------------------------------------------------------------------
# Cache line constants
# ---------------------------------------------------------------------------

# Phase A note (delete in Phase B): nim-debra's existing `types.nim`
# imports both `atomics` (this file) and `./constants` (which already
# defines `CacheLineBytes` with the same `{.intdefine.}` shape). To
# avoid an ambiguous-identifier error during Phase A, we re-export
# the existing `constants.CacheLineBytes` rather than redefining it
# here. Phase B drops `constants.nim` and lets this module own the
# definition outright.
## `CacheLineBytes`: bytes per L1 cache line. 128 on PowerPC, 64
## elsewhere. Override with `-d:CacheLineBytes=N`.
import ./constants
export constants.CacheLineBytes

template cacheLineAligned*(decl: untyped) =
  ## Drop-in `{.align: CacheLineBytes.}` shorthand.
  {.align: CacheLineBytes.}
  decl

# ---------------------------------------------------------------------------
# Type constraints and alignment
# ---------------------------------------------------------------------------

template assertAtomCompat(T: typedesc) =
  when T is ref:
    {.
      error:
        "Atomic[ref T] is forbidden. Use Atomic[ptr T] with " &
        "retain/release/releaseDestructor (see debra/refptr)."
    .}
  elif not supportsCopyMem(T):
    {.
      error:
        "Atomic[T] requires T to be trivially copyable (no " &
        "GC-managed fields). For ref types, use Atomic[ptr T]."
    .}

# ---------------------------------------------------------------------------
# Lock-free enforcement
# ---------------------------------------------------------------------------

template assertLockFree(T: typedesc) =
  ## C-compile-time check that `Atomic[T]` ops are lock-free. Emits a
  ## static-assertion invoking `__atomic_always_lock_free`. Cannot run
  ## in the Nim VM (importc is unavailable there); the C compiler
  ## constant-folds the call. Bypass with
  ## `-d:debraAllowNonLockFreeAtomics`.
  ##
  ## Form depends on the active backend: `_Static_assert` is the C11
  ## keyword and is rejected by GCC's C++ frontend; `static_assert` is
  ## the C++11 keyword and is rejected by older C frontends. (Apple's
  ## clang accepts both in either mode, which is why this divergence
  ## only surfaces on Linux g++.)
  when not defined(debraAllowNonLockFreeAtomics):
    when defined(cpp):
      {.
        emit: [
          "static_assert(__atomic_always_lock_free(sizeof(",
          T,
          "), 0), \"Atomic[" & astToStr(T) & "] is not lock-free on this target; pass " &
            "-d:debraAllowNonLockFreeAtomics to override\");",
        ]
      .}
    else:
      {.
        emit: [
          "_Static_assert(__atomic_always_lock_free(sizeof(",
          T,
          "), 0), \"Atomic[" & astToStr(T) & "] is not lock-free on this target; pass " &
            "-d:debraAllowNonLockFreeAtomics to override\");",
        ]
      .}
  else:
    # Fallback path: caller opted in to libatomic spinlock when the type is
    # not always-lock-free at the requested width. The design doc
    # (`docs/design/2026-04-25-custom-atomics.md` section 3.1) mandates a
    # compile-time warning at the call site so the relaxation is visible
    # in build output. The warning fires once per `T` instantiation since
    # `assertLockFree` is invoked from `enforceAtomicConstraints`'s `static`
    # block, which is itself per-`T`.
    {.
      warning:
        "Atomic[" & astToStr(T) &
        "] is not guaranteed lock-free on this target; if the C compiler " &
        "selects the libatomic spinlock fallback the lock-free guarantee " &
        "is lost. Compiled with -d:debraAllowNonLockFreeAtomics; verify " &
        "the target supports the fallback at acceptable cost."
    .}

# ---------------------------------------------------------------------------
# Pair[A, B]  (DWCAS substrate)
# ---------------------------------------------------------------------------

type Pair*[A, B] = object
  ## 16-byte-aligned object wrapper for DWCAS. Both halves must satisfy
  ## `supportsCopyMem`, each must be `<= 8` bytes, and `sizeof(A) + sizeof(B)`
  ## must equal 16. Domain-neutral field names: `first` and `second`.
  ##
  ## Conventional LCRQ usage spells `Pair[uint64, T]` where `first` is a
  ## monotonically-bumped sequence counter (ABA defense) and `second` is the
  ## payload. Generation overflow is documented as impossible in practical
  ## lifetimes (uint64 monotonicity).
  ##
  ## Field-level `{.align: 16.}` on `first*` elevates the whole object to
  ## 16-byte alignment per Nim 2.2.10 align-pragma scope rules; the
  ## object-level form (`type Pair {.align: 16.} = object ...`) is rejected.
  ##
  ## `ptr T` fields are explicitly opt-out of ARC: `Pair` makes no claim
  ## on the lifetime of whatever a contained `ptr` points at.
  ##
  ## See `docs/guide/atomics.md` §7 for an LCRQ-style worked example
  ## using `Pair[uint64, ptr Node]`.
  first* {.align: 16.}: A
  second*: B

template enforceDwcasConstraints*(A, B: typedesc) =
  ## Gate 2 (Pair shape) + Gate 4 (lock-free) for `Atomic[Pair[A, B]]`.
  ##
  ## Checks `sizeof(A) + sizeof(B) == 16` rather than `sizeof(Pair[A, B]) == 16`:
  ## the field-level `{.align: 16.}` on `first` pads any undersized Pair up to
  ## 16 bytes, so the outer sizeof would silently mask half-size mismatches
  ## (e.g. `Pair[uint64, uint32]` has 12 bytes of payload + 4 padding). DWCAS
  ## requires both halves live (cmpxchg16b / casp compares all 128 bits), so
  ## the payload sum is the real safety invariant.
  static:
    assert sizeof(pointer) == 8,
      "DWCAS / 128-bit atomics require a 64-bit target " &
        "(sizeof(pointer) must be 8). nim-debra's Atomic[Pair[A, B]] / 16-byte " &
        "atomic ops are unavailable on 32-bit ABIs. The 1-, 2-, 4-, and 8-byte " &
        "Atomic[T] surface in debra/atomics remains available on 32-bit."
    assert sizeof(A) <= 8,
      "Pair half-type sizeof(" & $A & ") = " & $sizeof(A) &
        " must be <= 8 bytes (DWCAS pairs two 64-bit registers)"
    assert sizeof(B) <= 8,
      "Pair half-type sizeof(" & $B & ") = " & $sizeof(B) &
        " must be <= 8 bytes (DWCAS pairs two 64-bit registers)"
    assert sizeof(A) + sizeof(B) == 16,
      "Pair[" & $A & ", " & $B & "] must be exactly 16 bytes; got " &
        $(sizeof(A) + sizeof(B)) & " (sizeof(" & $A & ")=" & $sizeof(A) & ", sizeof(" &
        $B & ")=" & $sizeof(B) & ")"
    assert alignof(Pair[A, B]) == 16,
      "Pair[" & $A & ", " & $B & "] must be 16-byte aligned; got " & $alignof(
        Pair[A, B]
      )
    assert supportsCopyMem(A),
      "Pair half-type must be supportsCopyMem; " & $A & " is not"
    assert supportsCopyMem(B),
      "Pair half-type must be supportsCopyMem; " & $B & " is not"
  # Gate 4 (lock-free) is enforced inside the concrete dwcas* op
  # specializations (tasks 7-11) via the `_Static_assert` /
  # `static_assert` emit. Calling `assertLockFree(Pair[A, B])` here
  # from inside a generic template body triggers a Nim 2.2.10
  # `expr(nkBracketExpr, tyGenericBody)` internal compiler error.

# ---------------------------------------------------------------------------
# Gate 1: 64-bit-only constraint
# ---------------------------------------------------------------------------
#
# DWCAS / 128-bit atomics require a 64-bit ABI (cmpxchg16b on x86_64,
# casp on aarch64; both pair two 64-bit registers). The 64-bit constraint
# is enforced per-instantiation inside `enforceDwcasConstraints*` above,
# so a 32-bit target compiles `debra/atomics` cleanly (preserving the
# 1-, 2-, 4-, and 8-byte `Atomic[T]` surface) and fails only when a user
# actually instantiates `Atomic[Pair[A, B]]`.
#
# The size-16 op specializations themselves (`dwcasLoad`, `dwcasStore`,
# `dwcasCasStrong`, `dwcasCasWeak`, and their `Atomic[Pair[A, B]]` op
# wrappers) sit inside a `when sizeof(pointer) == 8:` block lower in this
# file so they don't appear at all on 32-bit (where the `__int128` /
# `cmpxchg16b` references inside their emit bodies would not compile).
# The `Pair[A, B]` type itself is defined at module level (it's a harmless
# struct on 32-bit) so it remains spellable; only `Atomic[Pair[A, B]]` ops
# are gated.

# ---------------------------------------------------------------------------
# Atomic[T]
# ---------------------------------------------------------------------------

type Atomic*[T] = object
  ## Atomic wrapper for `T`. Lock-free on this target; rejects
  ## `ref T`.
  ##
  ## Supports 1-, 2-, 4-, and 8-byte types only. 16-byte types
  ## (`__int128`, double-quadword pointers) require a different code
  ## path (`cmpxchg16b` on x86_64, `casp` on aarch64) and are not
  ## currently provided. Such instantiations fail with a compile-time
  ## `{.error.}` from the underlying `nonAtomicType` template.
  ##
  ## Note on alignment: Nim's field-level `{.align: ...}` pragma
  ## cannot reference `sizeof(T)` from a generic context (as of
  ## Nim 2.2.6 it triggers `sizeof requires .importc types to be
  ## .completeStruct`). We therefore rely on `T`'s natural alignment
  ## — which is `>= sizeof(T)` for the primitives we ship on every
  ## 64-bit ABI we currently target, but is **not** universally true.
  ## Notably, on i386 System V `alignof(uint64) == 4`, which would
  ## yield a split-lock object that is not always-lock-free.
  ##
  ## `enforceAtomicConstraints` therefore fires
  ## `static: assert alignof(Atomic[T]) >= sizeof(T)` per instantiation;
  ## a target where natural alignment is insufficient fails to compile
  ## rather than silently producing a non-lock-free object. If we ever
  ## need to support such a target, the fix is a per-size specialisation
  ## that boxes `T` in a struct with an explicit `{.align: 8.}` (or
  ## similar) field; the generic path cannot do better today.
  value: T

# Compile-time gates fire when the type is referenced in a real
# definition. Wrapping in a no-op proc forces instantiation.
template enforceAtomicConstraints(T: typedesc) =
  assertAtomCompat(T)
  assertLockFree(T)
  when not defined(debraAllowNonLockFreeAtomics):
    static:
      assert alignof(Atomic[T]) >= sizeof(T),
        "alignment guard for Atomic[" & $T & "] failed " & "(alignof=" &
          $alignof(Atomic[T]) & ", sizeof=" & $sizeof(T) & ")"

# ---------------------------------------------------------------------------
# Memory-order validation per op
# ---------------------------------------------------------------------------

template validLoadOrder(order: MemoryOrder) =
  static:
    assert order != moRelease and order != moAcquireRelease,
      "moRelease / moAcquireRelease is not a valid memory order " &
        "for load; use moRelaxed, moConsume, moAcquire, or " & "moSequentiallyConsistent"

template validStoreOrder(order: MemoryOrder) =
  static:
    assert order != moAcquire and order != moAcquireRelease and order != moConsume,
      "moAcquire / moAcquireRelease / moConsume is not a valid " &
        "memory order for store; use moRelaxed, moRelease, or " &
        "moSequentiallyConsistent"

template validCasFailureOrder(success, failure: MemoryOrder) =
  static:
    assert failure != moRelease and failure != moAcquireRelease,
      "compareExchange failure order moRelease / moAcquireRelease " &
        "is invalid; failure must be moRelaxed, moConsume, " &
        "moAcquire, or moSequentiallyConsistent"
    # C11 §7.17.7.4: failure order must be no stronger than the LOAD
    # component of the success order. `moRelease` has no load-acquire on
    # the success path, so the failure load cannot acquire either —
    # `success=moRelease, failure=moAcquire` is invalid even though
    # `ord(moAcquire) <= ord(moRelease)`. Other success orders use the
    # ordinal comparison correctly for the lattice.
    when success == moRelease:
      assert failure == moRelaxed,
        "compareExchange failure with success=moRelease requires " &
          "failure=moRelaxed (moRelease has no load-acquire component " &
          "for the failure path; use moAcquireRelease as success if you " &
          "need acquire-on-failure)"
    else:
      assert ord(failure) <= ord(success),
        "compareExchange failure order is stronger than success " &
          "order; failure must be <= success"

func casFailureFromSuccess(s: MemoryOrder): MemoryOrder {.compileTime.} =
  ## Derive a CAS failure order from a success order per C11: drop the
  ## release component. `moRelease` -> `moRelaxed`,
  ## `moAcquireRelease` -> `moAcquire`, all others unchanged.
  case s
  of moRelease: moRelaxed
  of moAcquireRelease: moAcquire
  else: s

# ---------------------------------------------------------------------------
# Loads and stores
# ---------------------------------------------------------------------------

# Map a Trivial Nim type to an integer of the same size accepted by the
# `__atomic_*_n` builtins. Used to atomically transfer non-AtomType
# values (enums, smaller bools) through the AtomType-typed builtins via
# bitwise cast.
template nonAtomicType*(T: typedesc): typedesc =
  when sizeof(T) == 1:
    int8
  elif sizeof(T) == 2:
    int16
  elif sizeof(T) == 4:
    int32
  elif sizeof(T) == 8:
    int64
  else:
    {.error: "no nonAtomicType for " & $T.}

proc load*[T](
    loc: var Atomic[T], order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  validLoadOrder(order)
  cast[T](atomicLoadN(cast[ptr nonAtomicType(T)](addr loc.value), toAtomMemModel(order)))

proc store*[T](
    loc: var Atomic[T], desired: T, order: static MemoryOrder = moSequentiallyConsistent
) {.inline.} =
  enforceAtomicConstraints(T)
  validStoreOrder(order)
  atomicStoreN(
    cast[ptr nonAtomicType(T)](addr loc.value),
    cast[nonAtomicType(T)](desired),
    toAtomMemModel(order),
  )

# ---------------------------------------------------------------------------
# Read-modify-write
# ---------------------------------------------------------------------------

proc exchange*[T](
    loc: var Atomic[T], desired: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  cast[T](atomicExchangeN(
    cast[ptr nonAtomicType(T)](addr loc.value),
    cast[nonAtomicType(T)](desired),
    toAtomMemModel(order),
  ))

proc compareExchangeStrong*[T](
    loc: var Atomic[T],
    expected: var T,
    desired: T,
    success: static MemoryOrder,
    failure: static MemoryOrder,
): bool {.inline.} =
  ## Strong CAS. On success, swaps `desired` into `loc`. On failure,
  ## overwrites `expected` with the current value of `loc`.
  enforceAtomicConstraints(T)
  validCasFailureOrder(success, failure)
  atomicCompareExchangeN(
    cast[ptr nonAtomicType(T)](addr loc.value),
    cast[ptr nonAtomicType(T)](addr expected),
    cast[nonAtomicType(T)](desired),
    weak = false,
    toAtomMemModel(success),
    toAtomMemModel(failure),
  )

proc compareExchangeWeak*[T](
    loc: var Atomic[T],
    expected: var T,
    desired: T,
    success: static MemoryOrder,
    failure: static MemoryOrder,
): bool {.inline.} =
  ## Weak CAS. May fail spuriously on platforms (notably ARM LL/SC)
  ## even when current value equals `expected`. Cheaper inside a loop.
  enforceAtomicConstraints(T)
  validCasFailureOrder(success, failure)
  atomicCompareExchangeN(
    cast[ptr nonAtomicType(T)](addr loc.value),
    cast[ptr nonAtomicType(T)](addr expected),
    cast[nonAtomicType(T)](desired),
    weak = true,
    toAtomMemModel(success),
    toAtomMemModel(failure),
  )

proc compareExchangeStrong*[T](
    loc: var Atomic[T], expected: var T, desired: T, order: static MemoryOrder
): bool {.inline.} =
  ## Strong CAS, single-order form. Failure order is derived from
  ## success per C11 (drop the release component): `moRelease` ->
  ## `moRelaxed`, `moAcquireRelease` -> `moAcquire`, otherwise
  ## unchanged. Use the five-arg form to spell the failure order
  ## explicitly.
  compareExchangeStrong(loc, expected, desired, order, casFailureFromSuccess(order))

proc compareExchangeWeak*[T](
    loc: var Atomic[T], expected: var T, desired: T, order: static MemoryOrder
): bool {.inline.} =
  ## Weak CAS, single-order form. Failure order is derived from
  ## success per `compareExchangeStrong`'s single-order overload.
  compareExchangeWeak(loc, expected, desired, order, casFailureFromSuccess(order))

proc compareExchangeStrong*[T](
    loc: var Atomic[T], expected: var T, desired: T
): bool {.inline.} =
  ## Strong CAS, default-order form. Equivalent to passing
  ## `moSequentiallyConsistent` for both success and failure.
  compareExchangeStrong(
    loc, expected, desired, moSequentiallyConsistent, moSequentiallyConsistent
  )

proc compareExchangeWeak*[T](
    loc: var Atomic[T], expected: var T, desired: T
): bool {.inline.} =
  ## Weak CAS, default-order form. Equivalent to passing
  ## `moSequentiallyConsistent` for both success and failure.
  compareExchangeWeak(
    loc, expected, desired, moSequentiallyConsistent, moSequentiallyConsistent
  )

# ---------------------------------------------------------------------------
# compareExchange aliases (unsuffixed name, std/atomics-compatible spelling)
# Defined after all compareExchangeStrong overloads so each alias resolves
# against a fully-defined target.
# ---------------------------------------------------------------------------

proc compareExchange*[T](
    loc: var Atomic[T],
    expected: var T,
    desired: T,
    success: static MemoryOrder,
    failure: static MemoryOrder,
): bool {.inline.} =
  ## Strong compare-and-exchange. Unsuffixed-name alias for
  ## `compareExchangeStrong`, matching the spelling used by clients
  ## migrating from `std/atomics`.
  compareExchangeStrong(loc, expected, desired, success, failure)

proc compareExchange*[T](
    loc: var Atomic[T], expected: var T, desired: T, order: static MemoryOrder
): bool {.inline.} =
  ## Strong CAS, single-order form. Failure order is derived from
  ## success per C11 (drop the release component). Alias for
  ## `compareExchangeStrong`.
  compareExchangeStrong(loc, expected, desired, order)

proc compareExchange*[T](
    loc: var Atomic[T], expected: var T, desired: T
): bool {.inline.} =
  ## Strong CAS, default-order form. Equivalent to passing
  ## `moSequentiallyConsistent` for both success and failure. Alias
  ## for `compareExchangeStrong`.
  compareExchangeStrong(loc, expected, desired)

# ---------------------------------------------------------------------------
# Numeric (SomeInteger only)
# ---------------------------------------------------------------------------

proc fetchAdd*[T: SomeInteger](
    loc: var Atomic[T], v: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  cast[T](atomicFetchAdd(
    cast[ptr nonAtomicType(T)](addr loc.value),
    cast[nonAtomicType(T)](v),
    toAtomMemModel(order),
  ))

proc fetchSub*[T: SomeInteger](
    loc: var Atomic[T], v: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  cast[T](atomicFetchSub(
    cast[ptr nonAtomicType(T)](addr loc.value),
    cast[nonAtomicType(T)](v),
    toAtomMemModel(order),
  ))

proc fetchAnd*[T: SomeInteger](
    loc: var Atomic[T], v: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  cast[T](atomicFetchAnd(
    cast[ptr nonAtomicType(T)](addr loc.value),
    cast[nonAtomicType(T)](v),
    toAtomMemModel(order),
  ))

proc fetchOr*[T: SomeInteger](
    loc: var Atomic[T], v: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  cast[T](atomicFetchOr(
    cast[ptr nonAtomicType(T)](addr loc.value),
    cast[nonAtomicType(T)](v),
    toAtomMemModel(order),
  ))

proc fetchXor*[T: SomeInteger](
    loc: var Atomic[T], v: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  cast[T](atomicFetchXor(
    cast[ptr nonAtomicType(T)](addr loc.value),
    cast[nonAtomicType(T)](v),
    toAtomMemModel(order),
  ))

# ---------------------------------------------------------------------------
# Numeric (SomeFloat)
# ---------------------------------------------------------------------------
#
# `load`, `store`, `exchange`, and `compareExchange*` already accept
# float32/float64 through the generic `T` overloads above: those route
# through `nonAtomicType(T)` which maps any 4-byte type to `int32` and
# any 8-byte type to `int64`, and the `cast[T](...)` on the way out
# reinterprets the integer bits back as the float. The bit-level
# transfer is exactly what we want for atomics on floats: -0.0 and NaN
# payloads round-trip exactly, and CAS uses bit-equality (matching the
# semantics of `std::atomic<float>` in C++ and `AtomicU32::as_float`
# patterns in other languages). `assertLockFree`'s
# `__atomic_always_lock_free(sizeof(T), 0)` is sizeof-based and
# accepts floats on every target where the equivalent integer width
# is lock-free.
#
# What's missing for floats is a hardware atomic add: GCC's
# `__atomic_fetch_add_n` builtins are integer-only on float operands.
# We provide `fetchAdd` for `SomeFloat` via a CAS-loop. Other
# fetch-bitwise ops (`fetchAnd`/`fetchOr`/`fetchXor`) are deliberately
# NOT provided for floats: bitwise operations on float values have no
# meaningful semantics. `fetchSub` is omitted because `fetchAdd(-x)`
# expresses the same operation cleanly.

proc fetchAdd*[T: SomeFloat](
    loc: var Atomic[T], v: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  ## Atomically add `v` to the float value at `loc` and return the
  ## previous value. Implemented as a `compareExchangeWeak` CAS-loop
  ## because GCC's `__atomic_fetch_add_n` is integer-only.
  ##
  ## Semantics: the read-add-CAS cycle is repeated until the CAS
  ## succeeds, so the returned old value and the new stored value
  ## together reflect a coherent atomic update of `loc`. Under
  ## contention, the loop may iterate multiple times.
  ##
  ## `order` is applied to the successful CAS; the failure order is
  ## derived per C11 (drops the release component).
  ##
  ## Bit-pattern fidelity caveat: `fetchAdd` performs an IEEE-754
  ## float addition; unlike `load`/`store`/`exchange`/`compareExchange*`
  ## (pure bitwise transfer), the bit-pattern guarantees do NOT apply
  ## to the *new stored value*. Specifically:
  ##
  ##   * The returned old value IS bit-exact: it comes from a relaxed
  ##     load before the add and reflects the pre-RMW storage bits
  ##     verbatim (so e.g. a NaN payload in `loc` is preserved in the
  ##     return value).
  ##   * The new stored value is `old + v` computed by the FPU, which
  ##     means: NaN payloads are not preserved across the add (e.g.
  ##     `NaN_payload_A + 1.0` yields a quiet NaN with implementation-
  ##     defined payload, not `payload_A`); denormal results may flush
  ##     to zero if FTZ/DAZ is enabled in the calling thread's FPU
  ##     state; the rounding mode is whatever the FPU is currently set
  ##     to (round-to-nearest by default; modifiable via `fesetround`
  ##     on x86 or FPCR on ARM); and overflow produces +/-Inf.
  ##
  ## The CAS-loop preserves atomicity; these caveats are inherent to
  ## float arithmetic, not to this implementation.
  enforceAtomicConstraints(T)
  var old = load(loc, moRelaxed)
  while true:
    let desired = old + v
    if compareExchangeWeak(loc, old, desired, order):
      return old
    # On failure, `old` was overwritten with the current value of
    # `loc`; loop with the fresh value.

# ---------------------------------------------------------------------------
# Fences
# ---------------------------------------------------------------------------

proc threadFence*(order: MemoryOrder) {.inline.} =
  ## Full memory fence between threads. All memory orders are valid.
  atomicThreadFence(toAtomMemModel(order))

proc signalFence*(order: MemoryOrder) {.inline.} =
  ## Compiler-only fence. Prevents the compiler from reordering across
  ## the fence; emits no CPU instructions. All memory orders are valid.
  atomicSignalFence(toAtomMemModel(order))

# ---------------------------------------------------------------------------
# AtomicFlag
# ---------------------------------------------------------------------------

type AtomicFlag* = distinct uint8
  ## Boolean flag with `testAndSet` / `clear` semantics. Underlying
  ## byte must be 0 or 1; `__atomic_test_and_set` is
  ## implementation-defined for any other value, so do not poke the
  ## raw uint8 directly.

proc testAndSet*(
    loc: var AtomicFlag, order: static MemoryOrder = moSequentiallyConsistent
): bool {.inline.} =
  ## Atomically set the flag and return its previous value.
  atomicTestAndSet(cast[pointer](addr loc), toAtomMemModel(order))

proc clear*(
    loc: var AtomicFlag, order: static MemoryOrder = moSequentiallyConsistent
) {.inline.} =
  ## Atomically reset the flag to false. `order` must not be
  ## moAcquire / moAcquireRelease / moConsume.
  validStoreOrder(order)
  atomicClear(cast[pointer](addr loc), toAtomMemModel(order))

# ---------------------------------------------------------------------------
# DWCAS (size-16) specializations
# ---------------------------------------------------------------------------
#
# These helpers + procs parameterize `Atomic[Pair[A, B]]`, so they must
# follow the `Atomic[T]` and `Pair[A, B]` definitions. The gate-1 wrapper
# (32-bit error arm) is enforced earlier in this file; here we only need
# the positive-side `when sizeof(pointer) == 8:` to keep the block out of
# compilation on 32-bit targets (where it would reference an unavailable
# `__int128`).
#
# Per design §4.5: 5 ops × 2 backend arms = 10 paste-ready emit bodies.
# Dispatch is by COMPILER (gcc → __sync_*, clang/llvm_gcc → __atomic_*),
# not architecture: GCC's __atomic_* family at 16 bytes falls back to
# `__atomic_load_16` etc. library calls on BOTH x86_64 (no -mcx16 inline)
# AND aarch64 (no LSE inline), so the only consistent inlining path under
# gcc is `__sync_val_compare_and_swap` on `__int128` (cmpxchg16b / casp).
# Byte-for-byte fidelity to atomic128_ref.hpp (via the design doc) is the
# F1 closure invariant.
#
# Gate-3 inline static-assert: each helper opens with
# `_Static_assert(__GCC_HAVE_SYNC_COMPARE_AND_SWAP_16 ...)` (cpp backend:
# `static_assert(...)`). This catches `-mno-cx16` (x86) or missing
# `__ARM_FEATURE_ATOMICS` (aarch64) at C-compile time per design §5.1.

when sizeof(pointer) == 8:
  template dwcasGate3Assert() =
    ## Gate 3: `_Static_assert` that the C compiler has DWCAS lock-free
    ## support at this target's effective ISA level. C/C++ keyword split
    ## tracks the `assertLockFree` precedent.
    # Preprocessor directives (#if/#elif/#endif) embedded inside a
    # _Static_assert / static_assert argument list are undefined behavior
    # in standard C/C++ and may reject under strict compilers/static
    # analyzers. We hoist the #if cascade outside the assertion: a single
    # NIMDEBRA_DWCAS_OK macro carries the lock-free predicate, and the
    # assertion body itself is plain.
    # The NIMDEBRA_DWCAS_OK macro is resolved to a literal `1` or `0` inside
    # nested `#if`/`#else` blocks so the `static_assert` / `_Static_assert`
    # argument is always a plain integer constant. Referencing an undefined
    # macro (e.g., `__ARM_FEATURE_ATOMICS` on a non-LSE aarch64 toolchain or
    # `__GCC_HAVE_SYNC_COMPARE_AND_SWAP_16` on older GCCs) inside the
    # assertion expression itself would yield an "undeclared identifier"
    # compile error rather than the intended diagnostic. Preprocessor `#if`
    # treats undefined macros as 0, so the cascade below is safe.
    when defined(cpp):
      {.
        emit: [
          "\n#if defined(__aarch64__)\n",
          "  #if __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16 || __ARM_FEATURE_ATOMICS\n",
          "    #define NIMDEBRA_DWCAS_OK 1\n", "  #else\n",
          "    #define NIMDEBRA_DWCAS_OK 0\n", "  #endif\n", "#else\n",
          "  #if __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16\n",
          "    #define NIMDEBRA_DWCAS_OK 1\n", "  #else\n",
          "    #define NIMDEBRA_DWCAS_OK 0\n", "  #endif\n", "#endif\n",
          "static_assert(NIMDEBRA_DWCAS_OK, \"nim-debra DWCAS requires __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16 ",
          "(x86_64: needs -mcx16; aarch64: needs -march=armv8.1-a+lse or later)\");\n",
          "\n#undef NIMDEBRA_DWCAS_OK\n",
        ]
      .}
    else:
      {.
        emit: [
          "\n#if defined(__aarch64__)\n",
          "  #if __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16 || __ARM_FEATURE_ATOMICS\n",
          "    #define NIMDEBRA_DWCAS_OK 1\n", "  #else\n",
          "    #define NIMDEBRA_DWCAS_OK 0\n", "  #endif\n", "#else\n",
          "  #if __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16\n",
          "    #define NIMDEBRA_DWCAS_OK 1\n", "  #else\n",
          "    #define NIMDEBRA_DWCAS_OK 0\n", "  #endif\n", "#endif\n",
          "_Static_assert(NIMDEBRA_DWCAS_OK, \"nim-debra DWCAS requires __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16 ",
          "(x86_64: needs -mcx16; aarch64: needs -march=armv8.1-a+lse or later)\");\n",
          "\n#undef NIMDEBRA_DWCAS_OK\n",
        ]
      .}

  template dwcasLoad*[A, B](
      loc: var Atomic[Pair[A, B]], order: static MemoryOrder
  ): Pair[A, B] =
    ## Low-level 16-byte atomic load emit. Backend-dispatched by compiler:
    ## gcc → `__sync_val_compare_and_swap` on `__int128` (inlines
    ## `cmpxchg16b` on x86_64 with `-mcx16` and `casp` on aarch64 with
    ## `-march=armv8.1-a+lse`); clang / llvm_gcc → `__atomic_load_n` on
    ## `__int128`. Callers should prefer `load(Atomic[Pair[A, B]])`
    ## which carries the per-callsite memory-order validation and
    ## seq_cst-upgrade warning. Exposed for testing and for callers
    ## that have already validated the order policy externally.
    enforceDwcasConstraints(A, B)
    dwcasGate3Assert()
    var result: Pair[A, B]
    # In Nim, `var` parameters compile to pointers in generated C, so `&loc`
    # inside an emit body would take the address of the POINTER parameter
    # (`Atomic_Pair**`), not the atomic object itself. Bind `addr loc` to a
    # local `ptr` so the emit references the atomic object directly.
    let locPtr = addr loc
    let resultPtr = addr result
    # Backend dispatch (Option B, v0.10.0 cycle-12 CRITICAL fix): split by
    # COMPILER, not architecture. GCC's `__atomic_*_n` family at 16 bytes
    # emits library calls (`__atomic_load_16` etc.) on BOTH x86_64 AND
    # aarch64 — only `__sync_val_compare_and_swap` inlines `cmpxchg16b` /
    # `casp` on the respective ISAs. Clang inlines both families. Symmetric
    # 2-arm dispatch: gcc → __sync_*, clang/llvm_gcc → __atomic_*.
    when defined(gcc) and not defined(clang):
      {.
        emit: [
          "{ __int128 _zero = 0;",
          " __int128 _prev = __sync_val_compare_and_swap((__int128*)", locPtr,
          ", _zero, _zero);", " __builtin_memcpy(", resultPtr, ", &_prev, 16); }",
        ]
      .}
    elif defined(clang) or defined(llvm_gcc) or defined(nintendoswitch):
      {.
        emit: [
          "{ __int128 _v = __atomic_load_n((__int128*)", locPtr, ", __ATOMIC_SEQ_CST);",
          " __builtin_memcpy(", resultPtr, ", &_v, 16); }",
        ]
      .}
    else:
      {.error: "DWCAS unsupported backend / arch combo".}
    result

  proc load*[A, B](
      loc: var Atomic[Pair[A, B]], order: static MemoryOrder = moSequentiallyConsistent
  ): Pair[A, B] {.inline.} =
    ## 16-byte atomic load via DWCAS substrate. Returns the current value
    ## of `loc` as a `Pair[A, B]`. Always seq_cst at the instruction level;
    ## sub-seq_cst `order` values are accepted but upgraded with a compile-
    ## time warning (see §3 of the DWCAS design doc).
    validLoadOrder(order)
    when order != moSequentiallyConsistent:
      {.
        warning:
          "nim-debra DWCAS upgrades memory order to moSequentiallyConsistent " &
          "at the instruction level. Pass moSequentiallyConsistent to silence " &
          "this warning, or wrap the call site in `dwcasOrderRelaxedCAS:` if " &
          "the relaxation is intentional."
      .}
    # Gate 4 (`assertLockFree(Pair[A, B])`) is intentionally elided here:
    # Nim 2.2.10 still ICEs (`expr(nkBracketExpr, tyGenericBody)`) when the
    # template is invoked from inside a generic proc body — the `Pair[A, B]`
    # type expression remains in a generic-instantiation context even at
    # the concrete proc-surface level. Gate 3's `_Static_assert(
    # __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16)` inside the emit body is a
    # stricter C-level lock-free check (it asserts the specific 16-byte
    # capability rather than the generic `__atomic_always_lock_free`),
    # so gate 4 is operationally redundant at this width.
    when not defined(release):
      doAssert (cast[uint](addr loc) and 15'u) == 0'u, "DWCAS loc misaligned"
    dwcasLoad(loc, order)

  template dwcasStore*[A, B](
      loc: var Atomic[Pair[A, B]], desired: Pair[A, B], order: static MemoryOrder
  ) =
    ## Low-level 16-byte atomic store emit. Backend-dispatched (see
    ## `dwcasLoad`). Prefer `store(Atomic[Pair[A, B]])` for the
    ## validated, warning-emitting surface.
    enforceDwcasConstraints(A, B)
    dwcasGate3Assert()
    # See `dwcasLoad` for the rationale: `var` parameters compile to C pointers,
    # so we bind `addr loc` to a local `ptr` to reference the atomic object
    # directly inside the emit body. Bind `desired` to a `let` local first so
    # taking its address is safe even when callers pass an rvalue
    # (e.g., `dwcasStore(a, makePair(...))`).
    let locPtr = addr loc
    let desiredLocal = desired
    let desiredPtr = addr desiredLocal
    # Backend dispatch (Option B): see `dwcasLoad` for rationale. Two arms
    # (gcc → __sync_*, clang/llvm_gcc → __atomic_*) cover both x86_64 and
    # aarch64 without library-call fallbacks. CPU pause hint inside the
    # gcc retry loop (cycle-12 perf): `pause` on x86, `yield` on aarch64
    # reduces cache-line bouncing under contention; zero cost when
    # uncontended. Inserted via #if cascade since this arm covers both
    # ISAs.
    when defined(gcc) and not defined(clang):
      # Initial atomic load via cas-with-self (__sync_val_compare_and_swap
      # with expected=desired=0): returns the current 128-bit value
      # atomically without modifying loc (the swap is a no-op unless loc
      # actually holds 0, in which case writing 0 over 0 is also a no-op).
      # Standard idiom for atomic 16-byte load when only __sync_* builtins
      # are available. A plain `*(volatile __int128*)` read is NOT atomic
      # (the CPU may split it into two 64-bit loads, causing torn reads
      # under concurrent writes). On CAS failure, the retry loop reuses
      # __sync_val_compare_and_swap's atomically-observed prior value as
      # _prev for the next iteration.
      {.
        emit: [
          "{ __int128 _new; __builtin_memcpy(&_new, ", desiredPtr,
          ", 16); __int128 _prev = __sync_val_compare_and_swap((__int128*)", locPtr,
          ", 0, 0); __int128 _ret;",
          " do { _ret = __sync_val_compare_and_swap((__int128*)", locPtr,
          ", _prev, _new); if (_ret == _prev) break; _prev = _ret;",
          "\n#if defined(__x86_64__)\n", "__builtin_ia32_pause();\n",
          "#elif defined(__aarch64__)\n",
          "__asm__ volatile(\"yield\" ::: \"memory\");\n", "#endif\n", " } while (1); }",
        ]
      .}
    elif defined(clang) or defined(llvm_gcc) or defined(nintendoswitch):
      {.
        emit: [
          "{ __int128 _d; __builtin_memcpy(&_d, ", desiredPtr,
          ", 16); __atomic_store_n((__int128*)", locPtr, ", _d, __ATOMIC_SEQ_CST); }",
        ]
      .}
    else:
      {.error: "DWCAS unsupported backend / arch combo".}

  proc store*[A, B](
      loc: var Atomic[Pair[A, B]],
      desired: Pair[A, B],
      order: static MemoryOrder = moSequentiallyConsistent,
  ) {.inline.} =
    ## 16-byte atomic store via DWCAS substrate. Always seq_cst at the
    ## instruction level; sub-seq_cst `order` values emit a compile-time
    ## warning (see §3 of the DWCAS design doc).
    validStoreOrder(order)
    when order != moSequentiallyConsistent:
      {.
        warning:
          "nim-debra DWCAS upgrades memory order to moSequentiallyConsistent " &
          "at the instruction level. Pass moSequentiallyConsistent to silence " &
          "this warning, or wrap the call site in `dwcasOrderRelaxedCAS:` if " &
          "the relaxation is intentional."
      .}
    when not defined(release):
      doAssert (cast[uint](addr loc) and 15'u) == 0'u, "DWCAS loc misaligned"
    dwcasStore(loc, desired, order)

  template dwcasExchange*[A, B](
      loc: var Atomic[Pair[A, B]], desired: Pair[A, B], order: static MemoryOrder
  ): Pair[A, B] =
    ## Low-level 16-byte atomic exchange emit. Backend-dispatched
    ## (see `dwcasLoad`). Prefer `exchange(Atomic[Pair[A, B]])` for
    ## the validated, warning-emitting surface.
    enforceDwcasConstraints(A, B)
    dwcasGate3Assert()
    var result: Pair[A, B]
    # See `dwcasLoad` for the rationale: bind `addr loc` / `addr result` to
    # local `ptr` variables so the emit body references the underlying objects
    # rather than the address of the C pointer parameter. Bind `desired` to a
    # `let` local first so taking its address is safe even when callers pass
    # an rvalue (e.g., `dwcasExchange(a, makePair(...))`).
    let locPtr = addr loc
    let resultPtr = addr result
    let desiredLocal = desired
    let desiredPtr = addr desiredLocal
    # Backend dispatch (Option B): see `dwcasLoad` for rationale. CPU pause
    # hint inside gcc retry loop matches `dwcasStore`.
    when defined(gcc) and not defined(clang):
      # Same _prev reuse pattern as dwcasStore. Initial atomic load via
      # cas-with-self (__sync_val_compare_and_swap with expected=desired=0):
      # returns the current 128-bit value atomically without modifying loc.
      # A plain `*(volatile __int128*)` read is NOT atomic (may split into
      # two 64-bit loads). On CAS failure, __sync_val_compare_and_swap
      # returns the atomically-observed prior value, reused as _prev for
      # the next iteration.
      {.
        emit: [
          "{ __int128 _new; __builtin_memcpy(&_new, ", desiredPtr,
          ", 16); __int128 _prev = __sync_val_compare_and_swap((__int128*)", locPtr,
          ", 0, 0); __int128 _ret;",
          " do { _ret = __sync_val_compare_and_swap((__int128*)", locPtr,
          ", _prev, _new); if (_ret == _prev) break; _prev = _ret;",
          "\n#if defined(__x86_64__)\n", "__builtin_ia32_pause();\n",
          "#elif defined(__aarch64__)\n",
          "__asm__ volatile(\"yield\" ::: \"memory\");\n", "#endif\n", " } while (1);",
          " __builtin_memcpy(", resultPtr, ", &_prev, 16); }",
        ]
      .}
    elif defined(clang) or defined(llvm_gcc) or defined(nintendoswitch):
      {.
        emit: [
          "{ __int128 _d; __builtin_memcpy(&_d, ", desiredPtr,
          ", 16); __int128 _prev = __atomic_exchange_n((__int128*)", locPtr,
          ", _d, __ATOMIC_SEQ_CST);", " __builtin_memcpy(", resultPtr,
          ", &_prev, 16); }",
        ]
      .}
    else:
      {.error: "DWCAS unsupported backend / arch combo".}
    result

  proc exchange*[A, B](
      loc: var Atomic[Pair[A, B]],
      desired: Pair[A, B],
      order: static MemoryOrder = moSequentiallyConsistent,
  ): Pair[A, B] {.inline.} =
    ## 16-byte atomic exchange via DWCAS substrate. Atomically replaces the
    ## value at `loc` with `desired` and returns the prior value. Always
    ## seq_cst at the instruction level; sub-seq_cst `order` values emit a
    ## compile-time warning.
    when order != moSequentiallyConsistent:
      {.
        warning:
          "nim-debra DWCAS upgrades memory order to moSequentiallyConsistent " &
          "at the instruction level. Pass moSequentiallyConsistent to silence " &
          "this warning, or wrap the call site in `dwcasOrderRelaxedCAS:` if " &
          "the relaxation is intentional."
      .}
    when not defined(release):
      doAssert (cast[uint](addr loc) and 15'u) == 0'u, "DWCAS loc misaligned"
    dwcasExchange(loc, desired, order)

  template dwcasCasStrong*[A, B](
      loc: var Atomic[Pair[A, B]],
      expected: var Pair[A, B],
      desired: Pair[A, B],
      success: static MemoryOrder,
      failure: static MemoryOrder,
  ): bool =
    ## Low-level 16-byte strong CAS emit. Backend-dispatched (see
    ## `dwcasLoad`). On gcc maps to `__sync_val_compare_and_swap`
    ## (always-strong); on clang / llvm_gcc maps to
    ## `__atomic_compare_exchange_n` with the weak flag = 0. Prefer
    ## `compareExchangeStrong(Atomic[Pair[A, B]])` for the validated,
    ## warning-emitting surface.
    enforceDwcasConstraints(A, B)
    dwcasGate3Assert()
    var result: bool
    # See `dwcasLoad` for the rationale: both `loc` and `expected` are `var`
    # parameters that compile to C pointers, so bind their addresses to local
    # `ptr` variables before the emit body. Bind `desired` to a `let` local
    # first so taking its address is safe even when callers pass an rvalue.
    let locPtr = addr loc
    let expectedPtr = addr expected
    let desiredLocal = desired
    let desiredPtr = addr desiredLocal
    # Backend dispatch (Option B): see `dwcasLoad` for rationale.
    when defined(gcc) and not defined(clang):
      {.
        emit: [
          "{ __int128 _e; __builtin_memcpy(&_e, ", expectedPtr,
          ", 16); __int128 _d; __builtin_memcpy(&_d, ", desiredPtr,
          ", 16); __int128 _prev = __sync_val_compare_and_swap((__int128*)", locPtr,
          ", _e, _d);", " __builtin_memcpy(", expectedPtr, ", &_prev, 16);", " ",
          result, " = (_prev == _e); }",
        ]
      .}
    elif defined(clang) or defined(llvm_gcc) or defined(nintendoswitch):
      {.
        emit: [
          "{ __int128 _d; __builtin_memcpy(&_d, ", desiredPtr, ", 16); ", result,
          " = __atomic_compare_exchange_n((__int128*)", locPtr, ", (__int128*)",
          expectedPtr, ", _d, 0 /* strong */, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); }",
        ]
      .}
    else:
      {.error: "DWCAS unsupported backend / arch combo".}
    result

  proc compareExchangeStrong*[A, B](
      loc: var Atomic[Pair[A, B]],
      expected: var Pair[A, B],
      desired: Pair[A, B],
      success: static MemoryOrder,
      failure: static MemoryOrder,
  ): bool {.inline.} =
    ## Strong 16-byte CAS via DWCAS. On success, swaps `desired` into
    ## `loc` and returns true; `expected` is unchanged. On failure,
    ## overwrites `expected` with the current value of `loc` and returns
    ## false. Always seq_cst at the instruction level; sub-seq_cst
    ## `success`/`failure` values emit a compile-time warning.
    ##
    ## ABA / aliasing note: `expected` and `desired` MUST be distinct
    ## memory locations. On CAS failure, `expected` is overwritten in-place
    ## with the current value of `loc`; on success, `expected` is unchanged.
    ## Passing the same `var` location for both `expected` and `desired` is
    ## a defined-but-confusing pattern (the desired payload is read first,
    ## then `expected` is overwritten — but if `expected` and `desired`
    ## alias, the post-CAS `desired` is undefined). Callers MUST NOT alias
    ## them. The 1/2/4/8-byte CAS surface has the same contract; the
    ## 16-byte ops re-document it here because the wider value makes
    ## accidental aliasing more tempting in LCRQ-style consumer code.
    validCasFailureOrder(success, failure)
    when success != moSequentiallyConsistent or failure != moSequentiallyConsistent:
      {.
        warning:
          "nim-debra DWCAS upgrades memory order to moSequentiallyConsistent " &
          "at the instruction level. Pass moSequentiallyConsistent to silence " &
          "this warning, or wrap the call site in `dwcasOrderRelaxedCAS:` if " &
          "the relaxation is intentional."
      .}
    when not defined(release):
      doAssert (cast[uint](addr loc) and 15'u) == 0'u, "DWCAS loc misaligned"
    dwcasCasStrong(loc, expected, desired, success, failure)

  proc compareExchangeStrong*[A, B](
      loc: var Atomic[Pair[A, B]],
      expected: var Pair[A, B],
      desired: Pair[A, B],
      order: static MemoryOrder,
  ): bool {.inline.} =
    ## Strong 16-byte CAS, single-order form. Failure order is derived
    ## from `order` per C11 (drop the release component).
    ##
    ## ABA / aliasing note: `expected` and `desired` MUST be distinct
    ## memory locations. On CAS failure, `expected` is overwritten in-place
    ## with the current value of `loc`; on success, `expected` is unchanged.
    ## Passing the same `var` location for both `expected` and `desired` is
    ## a defined-but-confusing pattern (the desired payload is read first,
    ## then `expected` is overwritten — but if `expected` and `desired`
    ## alias, the post-CAS `desired` is undefined). Callers MUST NOT alias
    ## them. The 1/2/4/8-byte CAS surface has the same contract; the
    ## 16-byte ops re-document it here because the wider value makes
    ## accidental aliasing more tempting in LCRQ-style consumer code.
    compareExchangeStrong(loc, expected, desired, order, casFailureFromSuccess(order))

  proc compareExchangeStrong*[A, B](
      loc: var Atomic[Pair[A, B]], expected: var Pair[A, B], desired: Pair[A, B]
  ): bool {.inline.} =
    ## Strong 16-byte CAS, default-order form. Equivalent to passing
    ## `moSequentiallyConsistent` for both success and failure.
    ##
    ## ABA / aliasing note: `expected` and `desired` MUST be distinct
    ## memory locations. On CAS failure, `expected` is overwritten in-place
    ## with the current value of `loc`; on success, `expected` is unchanged.
    ## Passing the same `var` location for both `expected` and `desired` is
    ## a defined-but-confusing pattern (the desired payload is read first,
    ## then `expected` is overwritten — but if `expected` and `desired`
    ## alias, the post-CAS `desired` is undefined). Callers MUST NOT alias
    ## them. The 1/2/4/8-byte CAS surface has the same contract; the
    ## 16-byte ops re-document it here because the wider value makes
    ## accidental aliasing more tempting in LCRQ-style consumer code.
    compareExchangeStrong(
      loc, expected, desired, moSequentiallyConsistent, moSequentiallyConsistent
    )

  template dwcasCasWeak*[A, B](
      loc: var Atomic[Pair[A, B]],
      expected: var Pair[A, B],
      desired: Pair[A, B],
      success: static MemoryOrder,
      failure: static MemoryOrder,
  ): bool =
    ## Low-level 16-byte weak CAS emit. Backend-dispatched (see
    ## `dwcasLoad`). On gcc, `__sync_val_compare_and_swap` is always-strong
    ## on both x86_64 (`cmpxchg16b`) and aarch64+LSE (`casp`), so the
    ## weak/strong distinction is a no-op; on clang / llvm_gcc maps to
    ## `__atomic_compare_exchange_n` with weak=1, where ARMv8.0 LL/SC
    ## (no LSE) `stlxp` may genuinely fail spuriously, while aarch64
    ## FEAT_LSE / LSE2 (`caspal`, objdump-verified on Apple Silicon)
    ## is always-strong. Prefer
    ## `compareExchangeWeak(Atomic[Pair[A, B]])` for the validated,
    ## warning-emitting surface.
    enforceDwcasConstraints(A, B)
    dwcasGate3Assert()
    var result: bool
    # See `dwcasLoad` for the rationale: both `loc` and `expected` are `var`
    # parameters that compile to C pointers, so bind their addresses to local
    # `ptr` variables before the emit body. Bind `desired` to a `let` local
    # first so taking its address is safe even when callers pass an rvalue.
    let locPtr = addr loc
    let expectedPtr = addr expected
    let desiredLocal = desired
    let desiredPtr = addr desiredLocal
    # Backend dispatch (Option B): see `dwcasLoad` for rationale. On the
    # gcc arm, `__sync_val_compare_and_swap` is always-strong on both
    # x86_64 (`cmpxchg16b`) and aarch64+LSE (`casp`), so the weak/strong
    # distinction collapses there — body matches `dwcasCasStrong`'s gcc
    # arm (design §4.5.1 documents this fallthrough). On the clang/llvm_gcc
    # arm, `__atomic_compare_exchange_n` with weak=1 genuinely permits
    # spurious failure on ARMv8.0 LL/SC (`stlxp`); LSE `caspal` makes weak
    # equivalent to strong.
    when defined(gcc) and not defined(clang):
      {.
        emit: [
          "{ __int128 _e; __builtin_memcpy(&_e, ", expectedPtr,
          ", 16); __int128 _d; __builtin_memcpy(&_d, ", desiredPtr,
          ", 16); __int128 _prev = __sync_val_compare_and_swap((__int128*)", locPtr,
          ", _e, _d);", " __builtin_memcpy(", expectedPtr, ", &_prev, 16);", " ",
          result, " = (_prev == _e); }",
        ]
      .}
    elif defined(clang) or defined(llvm_gcc) or defined(nintendoswitch):
      {.
        emit: [
          "{ __int128 _d; __builtin_memcpy(&_d, ", desiredPtr, ", 16); ", result,
          " = __atomic_compare_exchange_n((__int128*)", locPtr, ", (__int128*)",
          expectedPtr, ", _d, 1 /* weak */, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); }",
        ]
      .}
    else:
      {.error: "DWCAS unsupported backend / arch combo".}
    result

  proc compareExchangeWeak*[A, B](
      loc: var Atomic[Pair[A, B]],
      expected: var Pair[A, B],
      desired: Pair[A, B],
      success: static MemoryOrder,
      failure: static MemoryOrder,
  ): bool {.inline.} =
    ## Weak 16-byte CAS via DWCAS. May fail spuriously only on ARMv8.0
    ## LL/SC cores (no LSE), where `stlxp` is permitted to fail without
    ## contention. On all other supported targets weak and strong are
    ## equivalent: x86_64 (`cmpxchg16b`) is always-strong; arm64 with
    ## FEAT_LSE / LSE2 (Apple Silicon, modern server chips) emits
    ## `caspal` for both procs (objdump-verified on Apple Silicon).
    ## Default to `compareExchangeStrong`; reach for Weak only after
    ## measuring a contention win on an ARMv8.0 target.
    ##
    ## ABA / aliasing note: `expected` and `desired` MUST be distinct
    ## memory locations. On CAS failure, `expected` is overwritten in-place
    ## with the current value of `loc`; on success, `expected` is unchanged.
    ## Passing the same `var` location for both `expected` and `desired` is
    ## a defined-but-confusing pattern (the desired payload is read first,
    ## then `expected` is overwritten — but if `expected` and `desired`
    ## alias, the post-CAS `desired` is undefined). Callers MUST NOT alias
    ## them. The 1/2/4/8-byte CAS surface has the same contract; the
    ## 16-byte ops re-document it here because the wider value makes
    ## accidental aliasing more tempting in LCRQ-style consumer code.
    validCasFailureOrder(success, failure)
    when success != moSequentiallyConsistent or failure != moSequentiallyConsistent:
      {.
        warning:
          "nim-debra DWCAS upgrades memory order to moSequentiallyConsistent " &
          "at the instruction level. Pass moSequentiallyConsistent to silence " &
          "this warning, or wrap the call site in `dwcasOrderRelaxedCAS:` if " &
          "the relaxation is intentional."
      .}
    when not defined(release):
      doAssert (cast[uint](addr loc) and 15'u) == 0'u, "DWCAS loc misaligned"
    dwcasCasWeak(loc, expected, desired, success, failure)

  proc compareExchangeWeak*[A, B](
      loc: var Atomic[Pair[A, B]],
      expected: var Pair[A, B],
      desired: Pair[A, B],
      order: static MemoryOrder,
  ): bool {.inline.} =
    ## Weak 16-byte CAS, single-order form. Failure order is derived
    ## from `order` per C11 (drop the release component).
    ##
    ## ABA / aliasing note: `expected` and `desired` MUST be distinct
    ## memory locations. On CAS failure, `expected` is overwritten in-place
    ## with the current value of `loc`; on success, `expected` is unchanged.
    ## Passing the same `var` location for both `expected` and `desired` is
    ## a defined-but-confusing pattern (the desired payload is read first,
    ## then `expected` is overwritten — but if `expected` and `desired`
    ## alias, the post-CAS `desired` is undefined). Callers MUST NOT alias
    ## them. The 1/2/4/8-byte CAS surface has the same contract; the
    ## 16-byte ops re-document it here because the wider value makes
    ## accidental aliasing more tempting in LCRQ-style consumer code.
    compareExchangeWeak(loc, expected, desired, order, casFailureFromSuccess(order))

  proc compareExchangeWeak*[A, B](
      loc: var Atomic[Pair[A, B]], expected: var Pair[A, B], desired: Pair[A, B]
  ): bool {.inline.} =
    ## Weak 16-byte CAS, default-order form. Equivalent to passing
    ## `moSequentiallyConsistent` for both success and failure. Mirrors
    ## the `compareExchangeStrong` default-order overload so that the
    ## two overload sets match shape-for-shape — relevant for callers
    ## migrating from `std/atomics`, whose `compareExchange*` procs all
    ## accept the no-order form.
    ##
    ## ABA / aliasing note: `expected` and `desired` MUST be distinct
    ## memory locations. On CAS failure, `expected` is overwritten in-place
    ## with the current value of `loc`; on success, `expected` is unchanged.
    ## Passing the same `var` location for both `expected` and `desired` is
    ## a defined-but-confusing pattern (the desired payload is read first,
    ## then `expected` is overwritten — but if `expected` and `desired`
    ## alias, the post-CAS `desired` is undefined). Callers MUST NOT alias
    ## them. The 1/2/4/8-byte CAS surface has the same contract; the
    ## 16-byte ops re-document it here because the wider value makes
    ## accidental aliasing more tempting in LCRQ-style consumer code.
    compareExchangeWeak(
      loc, expected, desired, moSequentiallyConsistent, moSequentiallyConsistent
    )

  # -------------------------------------------------------------------------
  # compareExchange aliases — route to Strong, std/atomics-compatible spelling.
  # Per design §2.2 and MED-5: every alias overload carries the verbatim
  # ABA/aliasing note block.
  # -------------------------------------------------------------------------

  proc compareExchange*[A, B](
      loc: var Atomic[Pair[A, B]],
      expected: var Pair[A, B],
      desired: Pair[A, B],
      success: static MemoryOrder,
      failure: static MemoryOrder,
  ): bool {.inline.} =
    ## Strong 16-byte CAS. Unsuffixed-name alias for
    ## `compareExchangeStrong`, matching the spelling used by clients
    ## migrating from `std/atomics`.
    ##
    ## ABA / aliasing note: `expected` and `desired` MUST be distinct
    ## memory locations. On CAS failure, `expected` is overwritten in-place
    ## with the current value of `loc`; on success, `expected` is unchanged.
    ## Passing the same `var` location for both `expected` and `desired` is
    ## a defined-but-confusing pattern (the desired payload is read first,
    ## then `expected` is overwritten — but if `expected` and `desired`
    ## alias, the post-CAS `desired` is undefined). Callers MUST NOT alias
    ## them. The 1/2/4/8-byte CAS surface has the same contract; the
    ## 16-byte ops re-document it here because the wider value makes
    ## accidental aliasing more tempting in LCRQ-style consumer code.
    compareExchangeStrong(loc, expected, desired, success, failure)

  proc compareExchange*[A, B](
      loc: var Atomic[Pair[A, B]],
      expected: var Pair[A, B],
      desired: Pair[A, B],
      order: static MemoryOrder,
  ): bool {.inline.} =
    ## Strong 16-byte CAS, single-order form. Alias for
    ## `compareExchangeStrong`.
    ##
    ## ABA / aliasing note: `expected` and `desired` MUST be distinct
    ## memory locations. On CAS failure, `expected` is overwritten in-place
    ## with the current value of `loc`; on success, `expected` is unchanged.
    ## Passing the same `var` location for both `expected` and `desired` is
    ## a defined-but-confusing pattern (the desired payload is read first,
    ## then `expected` is overwritten — but if `expected` and `desired`
    ## alias, the post-CAS `desired` is undefined). Callers MUST NOT alias
    ## them. The 1/2/4/8-byte CAS surface has the same contract; the
    ## 16-byte ops re-document it here because the wider value makes
    ## accidental aliasing more tempting in LCRQ-style consumer code.
    compareExchangeStrong(loc, expected, desired, order)

  proc compareExchange*[A, B](
      loc: var Atomic[Pair[A, B]], expected: var Pair[A, B], desired: Pair[A, B]
  ): bool {.inline.} =
    ## Strong 16-byte CAS, default-order form. Alias for
    ## `compareExchangeStrong`.
    ##
    ## ABA / aliasing note: `expected` and `desired` MUST be distinct
    ## memory locations. On CAS failure, `expected` is overwritten in-place
    ## with the current value of `loc`; on success, `expected` is unchanged.
    ## Passing the same `var` location for both `expected` and `desired` is
    ## a defined-but-confusing pattern (the desired payload is read first,
    ## then `expected` is overwritten — but if `expected` and `desired`
    ## alias, the post-CAS `desired` is undefined). Callers MUST NOT alias
    ## them. The 1/2/4/8-byte CAS surface has the same contract; the
    ## 16-byte ops re-document it here because the wider value makes
    ## accidental aliasing more tempting in LCRQ-style consumer code.
    compareExchangeStrong(loc, expected, desired)

  # -------------------------------------------------------------------------
  # Per-callsite memory-order silencer (design §3, Friction-1 closure).
  # Wraps a DWCAS call site in `{.push warning[User]: off.}` / `{.pop.}`
  # so that an intentional, audited memory-order relaxation (notably the
  # LCRQ producer publish CAS, which passes `moRelease`/`moRelaxed`) does
  # not emit the seq_cst-upgrade warning at that single site. Outside the
  # wrapper, the warning continues to fire for all other call sites.
  # -------------------------------------------------------------------------

  template dwcasOrderRelaxedCAS*(body: untyped): untyped =
    ## Wraps a DWCAS call site, suppressing the moSeqCst-upgrade
    ## warning emitted by the 16-byte ops (load / store / exchange /
    ## compareExchange*) for that site only. Use when the upgrade is
    ## intentional and audited (e.g. the LCRQ producer publish CAS
    ## passing `moRelease` / `moRelaxed`). The warning continues to
    ## fire at unwrapped call sites.
    ##
    ## See `docs/design/2026-04-25-custom-atomics.md` §3 and the
    ## user guide `docs/guide/atomics.md` §5 (Memory-order policy) for
    ## the memory-model rationale.
    {.push warning[User]: off.}
    body
    {.pop.}
