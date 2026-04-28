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
## Backend strategy: wrap GCC/Clang `__atomic_*_n` builtins (already
## bound by Nim's `std/sysatomics` module). MSVC fallback is a future
## item; this module currently requires gcc, clang, llvm_gcc, or the
## Nintendo Switch toolchain.

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
# Atomic[T]
# ---------------------------------------------------------------------------

type Atomic*[T] = object
  ## Atomic wrapper for `T`. Lock-free on this target; rejects
  ## `ref T`.
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
