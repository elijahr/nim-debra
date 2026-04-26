## debra/atomics
##
## Custom atomics for nim-debra (and lockfreequeues).
##
## Goals over std/atomics:
##   * Reject `Atomic[ref T]` at compile time (no silent spinlock).
##   * Require `Atomic[T]` to be lock-free at compile time.
##   * Validate `MemoryOrder` per op at compile time.
##   * Force natural alignment so 32-bit targets do not silently
##     downgrade `Atomic[uint64]` to a non-lock-free 4-byte object.
##
## Design doc: docs/design/2026-04-25-custom-atomics.md
##
## Backend strategy: wrap GCC/Clang `__atomic_*_n` builtins (already
## bound by Nim's `std/sysatomics` module). MSVC fallback is a future
## item; this module currently requires gcc, clang, llvm_gcc, or the
## Nintendo Switch toolchain.

import std/sysatomics

when not (defined(gcc) or defined(llvm_gcc) or defined(clang) or
          defined(nintendoswitch)):
  {.error: "debra/atomics currently requires gcc, clang, llvm_gcc, or " &
           "nintendoswitch (the GCC __atomic_* builtin family). MSVC " &
           "fallback is a future item.".}

# ---------------------------------------------------------------------------
# MemoryOrder
# ---------------------------------------------------------------------------

type
  MemoryOrder* = enum
    ## Specifies how non-atomic operations can be reordered around atomic
    ## operations. Ordinals match GCC's `__ATOMIC_*` so `ord(order)` is
    ## passed directly to the builtins.
    moRelaxed              ## No ordering constraints.
    moConsume              ## Accepted, mapped to moAcquire (mirrors std).
    moAcquire              ## No reordering of subsequent loads/stores before.
    moRelease              ## No reordering of preceding loads/stores after.
    moAcquireRelease       ## Both acquire and release on RMW.
    moSequentiallyConsistent ## Single total order across all SC ops.

template toAtomMemModel(o: MemoryOrder): AtomMemModel =
  cast[AtomMemModel](cint(ord(o)))

# ---------------------------------------------------------------------------
# Cache line constants
# ---------------------------------------------------------------------------

const CacheLineBytes* {.intdefine.} =
  when defined(powerpc): 128 else: 64
  ## Bytes per L1 cache line. 128 on PowerPC, 64 elsewhere. Override
  ## with `-d:CacheLineBytes=N`.

template cacheLineAligned*(decl: untyped) =
  ## Drop-in `{.align: CacheLineBytes.}` shorthand.
  {.align: CacheLineBytes.}
  decl

# ---------------------------------------------------------------------------
# Type constraints and alignment
# ---------------------------------------------------------------------------

template assertAtomCompat(T: typedesc) =
  when T is ref:
    {.error: "Atomic[ref T] is forbidden; use Managed[T] " &
             "(debra/managed.nim) or Atomic[ptr T]".}
  elif not (T is SomeInteger or T is ptr or T is bool or
            T is enum or T is pointer or T is char):
    {.error: "Atomic[T] only supports integers, ptr, bool, enum, " &
             "pointer, or char (got " & $T & ")".}

# ---------------------------------------------------------------------------
# Lock-free enforcement
# ---------------------------------------------------------------------------

template assertLockFree(T: typedesc) =
  ## C-compile-time check that `Atomic[T]` ops are lock-free. Emits a
  ## `_Static_assert` invoking `__atomic_always_lock_free`. Cannot run
  ## in the Nim VM (importc is unavailable there); the C compiler
  ## constant-folds the call. Bypass with
  ## `-d:debraAllowNonLockFreeAtomics`.
  when not defined(debraAllowNonLockFreeAtomics):
    {.emit: [
      "_Static_assert(__atomic_always_lock_free(sizeof(", T,
      "), 0), \"Atomic[", $T,
      "] is not lock-free on this target; pass " &
        "-d:debraAllowNonLockFreeAtomics to override\");"
    ].}

# ---------------------------------------------------------------------------
# Atomic[T]
# ---------------------------------------------------------------------------

type
  Atomic*[T] = object
    ## Atomic wrapper for `T`. Lock-free on this target; rejects
    ## `ref T`.
    ##
    ## Note on alignment: Nim's field-level `{.align: ...}` pragma
    ## cannot reference `sizeof(T)` from a generic context (as of
    ## Nim 2.2.6 it triggers `sizeof requires .importc types to be
    ## .completeStruct`). Instead we rely on `T`'s natural alignment
    ## (always >= sizeof(T) for primitives on 64-bit targets) and
    ## guard via `static: assert alignof(Atomic[T]) >= sizeof(T)`
    ## inside each op. If a 32-bit target ever trips that guard we
    ## will emit a per-size dispatch.
    value: T

# Compile-time gates fire when the type is referenced in a real
# definition. Wrapping in a no-op proc forces instantiation.
template enforceAtomicConstraints(T: typedesc) =
  assertAtomCompat(T)
  assertLockFree(T)
  static:
    assert alignof(Atomic[T]) >= sizeof(T),
      "alignment guard for Atomic[" & $T & "] failed " &
      "(alignof=" & $alignof(Atomic[T]) & ", sizeof=" & $sizeof(T) & ")"

# ---------------------------------------------------------------------------
# Memory-order validation per op
# ---------------------------------------------------------------------------

template validLoadOrder(order: MemoryOrder) =
  static:
    assert order != moRelease and order != moAcquireRelease,
      "moRelease / moAcquireRelease is not a valid memory order " &
      "for load; use moRelaxed, moConsume, moAcquire, or " &
      "moSequentiallyConsistent"

template validStoreOrder(order: MemoryOrder) =
  static:
    assert order != moAcquire and order != moAcquireRelease and
           order != moConsume,
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

# ---------------------------------------------------------------------------
# Loads and stores
# ---------------------------------------------------------------------------

# Map a Trivial Nim type to an integer of the same size accepted by the
# `__atomic_*_n` builtins. Used to atomically transfer non-AtomType
# values (enums, smaller bools) through the AtomType-typed builtins via
# bitwise cast.
template nonAtomicType*(T: typedesc): typedesc =
  when sizeof(T) == 1: int8
  elif sizeof(T) == 2: int16
  elif sizeof(T) == 4: int32
  elif sizeof(T) == 8: int64
  else:
    {.error: "no nonAtomicType for " & $T.}

proc load*[T](loc: var Atomic[T];
              order: static MemoryOrder = moSequentiallyConsistent): T {.inline.} =
  enforceAtomicConstraints(T)
  validLoadOrder(order)
  cast[T](atomicLoadN(
    cast[ptr nonAtomicType(T)](addr loc.value), toAtomMemModel(order)))

proc store*[T](loc: var Atomic[T]; desired: T;
               order: static MemoryOrder = moSequentiallyConsistent) {.inline.} =
  enforceAtomicConstraints(T)
  validStoreOrder(order)
  atomicStoreN(
    cast[ptr nonAtomicType(T)](addr loc.value),
    cast[nonAtomicType(T)](desired),
    toAtomMemModel(order))
