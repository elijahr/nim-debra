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
## Backend strategy: wrap GCC/Clang `__atomic_*_n` builtins for the
## unix toolchains (gcc, clang, llvm_gcc, nintendoswitch), and MSVC's
## `_Interlocked*` intrinsics family (declared in `<intrin.h>`) for vcc.
## The MSVC arms cover the full 1-, 2-, 4-, and 8-byte `Atomic[T]`
## surface plus AtomicFlag, fences, and the 16-byte DWCAS via
## `_InterlockedCompareExchange128`.
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
  defined(gcc) or defined(llvm_gcc) or defined(clang) or defined(nintendoswitch) or
  defined(vcc)
):
  {.
    error:
      "debra/atomics requires gcc, clang, llvm_gcc, nintendoswitch " &
      "(GCC __atomic_* builtin family), or vcc (MSVC _Interlocked* " &
      "intrinsics). Other backends (tcc, bcc, etc.) are not supported."
  .}

# ---------------------------------------------------------------------------
# MSVC intrinsics surface
# ---------------------------------------------------------------------------
#
# `std/sysatomics` only exposes a thin slice of the MSVC `_Interlocked*`
# family on vcc (load/store via barrier-stamp, CAS for sizes 1/4/8 on `ptr`,
# `_InterlockedExchangeAdd[64]` for `int`, plus `_ReadBarrier`/`_WriteBarrier`
# /`_ReadWriteBarrier`). debra/atomics requires the full surface:
# arbitrary `T` CAS at sizes 1/2/4/8, exchange at 1/2/4/8, fetch
# add/sub/and/or/xor at 1/2/4/8, test-and-set and clear for AtomicFlag,
# full thread/signal fences with explicit memory-order semantics, plus
# `_InterlockedCompareExchange128` for DWCAS. The block below declares
# the additional importc bindings needed for those wrappers.
#
# All MSVC `_Interlocked*` intrinsics are sequentially-consistent at the
# hardware level: they emit `lock`-prefixed instructions (or `xchg` which
# is implicitly locked) on x86_64. The memory-order parameter is therefore
# honored at the compiler-barrier level only (`_ReadWriteBarrier`); the
# instruction itself is always seq_cst. This matches the upgrade policy
# documented for the DWCAS 16-byte ops and is consistent with MSVC's
# documented semantics for these intrinsics (Microsoft Learn: "Intrinsics
# Available on All Architectures").

when defined(vcc):
  # Header pragma carrier — every emitted body includes <intrin.h>.
  {.emit: "#include <intrin.h>".}

  # The MSVC `_Interlocked*` intrinsics take typed pointers
  # (`volatile T*`). In C the implicit `void* -> T*` conversion makes
  # `pointer` (i.e. `void*`) work as the first argument; in C++ that
  # conversion is forbidden, so the cpp backend rejects every call.
  # Declare the pointer argument with the exact width-matched ptr
  # type so the C signature matches on both backends. Call sites
  # cast `addr loc.value` to the matching `ptr intN` before passing.
  #
  # ---- exchange (sizes 1/2/4/8) ----
  proc msvcInterlockedExchange8(
    p: ptr cchar, val: cchar
  ): cchar {.importc: "_InterlockedExchange8", header: "<intrin.h>".}

  proc msvcInterlockedExchange16(
    p: ptr cshort, val: cshort
  ): cshort {.importc: "_InterlockedExchange16", header: "<intrin.h>".}

  proc msvcInterlockedExchange32(
    p: ptr clong, val: clong
  ): clong {.importc: "_InterlockedExchange", header: "<intrin.h>".}

  proc msvcInterlockedExchange64(
    p: ptr clonglong, val: clonglong
  ): clonglong {.importc: "_InterlockedExchange64", header: "<intrin.h>".}

  # ---- compare-exchange (sizes 1/2/4/8) ----
  # MSVC signature: T _InterlockedCompareExchange*(volatile T* Dest,
  # T Exchange, T Comparand); returns the prior value at Dest.
  proc msvcInterlockedCompareExchange8(
    p: ptr cchar, exchange, comparand: cchar
  ): cchar {.importc: "_InterlockedCompareExchange8", header: "<intrin.h>".}

  proc msvcInterlockedCompareExchange16(
    p: ptr cshort, exchange, comparand: cshort
  ): cshort {.importc: "_InterlockedCompareExchange16", header: "<intrin.h>".}

  proc msvcInterlockedCompareExchange32(
    p: ptr clong, exchange, comparand: clong
  ): clong {.importc: "_InterlockedCompareExchange", header: "<intrin.h>".}

  proc msvcInterlockedCompareExchange64(
    p: ptr clonglong, exchange, comparand: clonglong
  ): clonglong {.importc: "_InterlockedCompareExchange64", header: "<intrin.h>".}

  # ---- fetch-add (sizes 1/2/4/8). fetch-sub = fetch-add with negated val. ----
  proc msvcInterlockedExchangeAdd8(
    p: ptr cchar, val: cchar
  ): cchar {.importc: "_InterlockedExchangeAdd8", header: "<intrin.h>".}

  proc msvcInterlockedExchangeAdd16(
    p: ptr cshort, val: cshort
  ): cshort {.importc: "_InterlockedExchangeAdd16", header: "<intrin.h>".}

  proc msvcInterlockedExchangeAdd32(
    p: ptr clong, val: clong
  ): clong {.importc: "_InterlockedExchangeAdd", header: "<intrin.h>".}

  proc msvcInterlockedExchangeAdd64(
    p: ptr clonglong, val: clonglong
  ): clonglong {.importc: "_InterlockedExchangeAdd64", header: "<intrin.h>".}

  # ---- fetch-and / fetch-or / fetch-xor (sizes 1/2/4/8) ----
  proc msvcInterlockedAnd8(
    p: ptr cchar, val: cchar
  ): cchar {.importc: "_InterlockedAnd8", header: "<intrin.h>".}

  proc msvcInterlockedAnd16(
    p: ptr cshort, val: cshort
  ): cshort {.importc: "_InterlockedAnd16", header: "<intrin.h>".}

  proc msvcInterlockedAnd32(
    p: ptr clong, val: clong
  ): clong {.importc: "_InterlockedAnd", header: "<intrin.h>".}

  proc msvcInterlockedAnd64(
    p: ptr clonglong, val: clonglong
  ): clonglong {.importc: "_InterlockedAnd64", header: "<intrin.h>".}

  proc msvcInterlockedOr8(
    p: ptr cchar, val: cchar
  ): cchar {.importc: "_InterlockedOr8", header: "<intrin.h>".}

  proc msvcInterlockedOr16(
    p: ptr cshort, val: cshort
  ): cshort {.importc: "_InterlockedOr16", header: "<intrin.h>".}

  proc msvcInterlockedOr32(
    p: ptr clong, val: clong
  ): clong {.importc: "_InterlockedOr", header: "<intrin.h>".}

  proc msvcInterlockedOr64(
    p: ptr clonglong, val: clonglong
  ): clonglong {.importc: "_InterlockedOr64", header: "<intrin.h>".}

  proc msvcInterlockedXor8(
    p: ptr cchar, val: cchar
  ): cchar {.importc: "_InterlockedXor8", header: "<intrin.h>".}

  proc msvcInterlockedXor16(
    p: ptr cshort, val: cshort
  ): cshort {.importc: "_InterlockedXor16", header: "<intrin.h>".}

  proc msvcInterlockedXor32(
    p: ptr clong, val: clong
  ): clong {.importc: "_InterlockedXor", header: "<intrin.h>".}

  proc msvcInterlockedXor64(
    p: ptr clonglong, val: clonglong
  ): clonglong {.importc: "_InterlockedXor64", header: "<intrin.h>".}

  # ---- iso-volatile load (sizes 1/2/4/8): pure load primitive.
  # `__iso_volatile_loadN` is a side-effect-free machine load; unlike
  # `_InterlockedCompareExchangeN(p, 0, 0)` it does NOT acquire the
  # cache line in Exclusive/Modified state, so true read-only loads
  # over common-zero values stay in Shared. The compile-barrier and
  # (on ARM64) `__dmb` for ordering are issued at the call site, since
  # `__iso_volatile_load*` is documented as a pure load with no fence.
  proc msvcIsoVolatileLoad8(
    p: ptr cchar
  ): cchar {.importc: "__iso_volatile_load8", header: "<intrin.h>".}

  proc msvcIsoVolatileLoad16(
    p: ptr cshort
  ): cshort {.importc: "__iso_volatile_load16", header: "<intrin.h>".}

  proc msvcIsoVolatileLoad32(
    p: ptr cint
  ): cint {.importc: "__iso_volatile_load32", header: "<intrin.h>".}

  proc msvcIsoVolatileLoad64(
    p: ptr clonglong
  ): clonglong {.importc: "__iso_volatile_load64", header: "<intrin.h>".}

  # ---- compiler reorder barrier (used as signalFence and as the
  # compile-barrier for sub-seq_cst fences) ----
  proc msvcReadWriteBarrier() {.importc: "_ReadWriteBarrier", header: "<intrin.h>".}

  # ---- full hardware memory fence for moSequentiallyConsistent
  # thread fences. We emit the underlying `<intrin.h>` primitives
  # directly rather than `MemoryBarrier`: that macro lives in
  # `<winnt.h>` (reached via `<windows.h>`), and pulling in the full
  # Windows SDK header just for a one-line fence inflates preprocessor
  # output by ~25k lines and pollutes the namespace with `min`/`max`/
  # `ERROR` macros that clash with C++ stdlib and other Nim code
  # (gemini cycle-29). Per Microsoft Learn `MemoryBarrier` expands to
  # `__faststorefence` on x86_64 and `__dmb(_ARM64_BARRIER_SY)` on
  # aarch64; both are declared in `<intrin.h>` which is already
  # included for the `_Interlocked*` intrinsics. The call site uses
  # an `{.emit:.}` with a `#ifdef _M_ARM64` dispatch, matching the
  # existing arch-dispatch pattern used elsewhere in this file. ----

  # NOTE: The 16-byte DWCAS path on vcc emits inline C calls to
  # `_InterlockedCompareExchange128` directly via `{.emit:.}` (see the
  # `dwcasCmpExch` family below). No Nim-level `importc` binding for
  # `_InterlockedCompareExchange128` is needed; an earlier declaration
  # was removed as dead code (gemini cycle-22).

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
    when defined(vcc):
      # MSVC does not provide `__atomic_always_lock_free`. The
      # `_Interlocked*` intrinsics family is always-lock-free for sizes
      # 1/2/4/8 on every Windows target we ship (x86_64 with
      # `cmpxchg`/`xchg`/`xadd`/etc., aarch64 with `casa`/`swpa`/`ldadda`
      # under FEAT_LSE or LL/SC fallback). The natural-alignment guard
      # `enforceAtomicConstraints` already asserts at the Nim level rules
      # out the 32-bit split-lock pathology that __atomic_always_lock_free
      # catches on GCC for `Atomic[uint64]` on i386 — vcc only targets 64-bit
      # Windows so sizeof(T) <= 8 with natural alignment is sufficient.
      # The check runs at Nim compile time via `static:` rather than as
      # an emitted C `_Static_assert`, because MSVC's C frontend in
      # default mode does not expose the `_Static_assert` keyword (it
      # parses as an implicit-int function declaration and fails at
      # link). The Nim-level check is equivalent — `sizeof(T)` is a
      # compile-time constant on both paths — and avoids needing to
      # toggle `/std:c11` for the C backend.
      static:
        assert sizeof(T) <= 8,
          "Atomic[" & astToStr(T) & "] vcc backend supports only " &
            "1/2/4/8 byte T (DWCAS handles 16 separately); pass " &
            "-d:debraAllowNonLockFreeAtomics to override"
    elif defined(cpp):
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
  when defined(vcc):
    # MSVC pure-load via `__iso_volatile_loadN` (from `<intrin.h>`).
    # The earlier implementation used `_InterlockedCompareExchange*(p, 0, 0)`,
    # which performs a CAS — a WRITE-class operation that acquires the
    # cache line in Exclusive/Modified state even when the swap fails
    # (the comparand-write is unconditional on x86 microarchitectures).
    # On hot read paths over a common-zero value that is a severe
    # footgun: every load steals the line from peer cores, generating
    # M-state traffic that real loads should never produce.
    #
    # `__iso_volatile_loadN` is a single, side-effect-free machine load
    # that the optimizer cannot reorder around. On x86_64 a width-≤8
    # naturally-aligned mov is atomic by the Intel SDM; on ARM64 the
    # corresponding `ldr` is atomic at single-copy granularity. We add
    # `_ReadWriteBarrier()` (compile barrier) after the load to prevent
    # the compiler from sinking subsequent ops above the load, and on
    # ARM64 a `__dmb(_ARM64_BARRIER_SY)` to upgrade the acquire-by-default
    # x86 semantics to seq_cst across the weaker ARM64 model. On x64,
    # the naked mov is already acquire under TSO; sub-seq_cst orders
    # are honored as compile barriers, matching the documented surface.
    {.emit: ["\n#ifdef _M_ARM64\n", "__dmb(_ARM64_BARRIER_SY);\n", "#endif\n"].}
    let raw =
      when sizeof(T) == 1:
        cast[T](msvcIsoVolatileLoad8(cast[ptr cchar](addr loc.value)))
      elif sizeof(T) == 2:
        cast[T](msvcIsoVolatileLoad16(cast[ptr cshort](addr loc.value)))
      elif sizeof(T) == 4:
        cast[T](msvcIsoVolatileLoad32(cast[ptr cint](addr loc.value)))
      elif sizeof(T) == 8:
        cast[T](msvcIsoVolatileLoad64(cast[ptr clonglong](addr loc.value)))
      else:
        {.error: "Atomic[T] vcc load supports only 1/2/4/8 byte T".}
    {.
      emit: [
        "_ReadWriteBarrier();\n", "#ifdef _M_ARM64\n", "__dmb(_ARM64_BARRIER_SY);\n",
        "#endif\n",
      ]
    .}
    raw
  else:
    cast[T](atomicLoadN(
      cast[ptr nonAtomicType(T)](addr loc.value), toAtomMemModel(order)
    ))

proc store*[T](
    loc: var Atomic[T], desired: T, order: static MemoryOrder = moSequentiallyConsistent
) {.inline.} =
  enforceAtomicConstraints(T)
  validStoreOrder(order)
  when defined(vcc):
    # Atomic store via `_InterlockedExchange*` (discard the prior value).
    # The exchange itself is seq_cst on x86_64; sub-seq_cst orders are
    # honored as compile-barriers via the implicit barrier in the
    # function call.
    when sizeof(T) == 1:
      discard
        msvcInterlockedExchange8(cast[ptr cchar](addr loc.value), cast[cchar](desired))
    elif sizeof(T) == 2:
      discard msvcInterlockedExchange16(
        cast[ptr cshort](addr loc.value), cast[cshort](desired)
      )
    elif sizeof(T) == 4:
      discard
        msvcInterlockedExchange32(cast[ptr clong](addr loc.value), cast[clong](desired))
    elif sizeof(T) == 8:
      discard msvcInterlockedExchange64(
        cast[ptr clonglong](addr loc.value), cast[clonglong](desired)
      )
    else:
      {.error: "Atomic[T] vcc store supports only 1/2/4/8 byte T".}
  else:
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
  when defined(vcc):
    when sizeof(T) == 1:
      cast[T](msvcInterlockedExchange8(
        cast[ptr cchar](addr loc.value), cast[cchar](desired)
      ))
    elif sizeof(T) == 2:
      cast[T](msvcInterlockedExchange16(
        cast[ptr cshort](addr loc.value), cast[cshort](desired)
      ))
    elif sizeof(T) == 4:
      cast[T](msvcInterlockedExchange32(
        cast[ptr clong](addr loc.value), cast[clong](desired)
      ))
    elif sizeof(T) == 8:
      cast[T](msvcInterlockedExchange64(
        cast[ptr clonglong](addr loc.value), cast[clonglong](desired)
      ))
    else:
      {.error: "Atomic[T] vcc exchange supports only 1/2/4/8 byte T".}
  else:
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
  when defined(vcc):
    # MSVC `_InterlockedCompareExchange*` returns the prior value.
    # success ⇔ (prior == expected). On failure, overwrite `expected`
    # with the prior value to match the C11 / __atomic_compare_exchange
    # contract. Always-strong (no spurious failure on x86_64).
    when sizeof(T) == 1:
      let exp8 = cast[int8](expected)
      let prev = msvcInterlockedCompareExchange8(
        cast[ptr cchar](addr loc.value), cast[cchar](desired), exp8
      )
      let ok = prev == exp8
      if not ok:
        expected = cast[T](prev)
      ok
    elif sizeof(T) == 2:
      let exp16 = cast[int16](expected)
      let prev = msvcInterlockedCompareExchange16(
        cast[ptr cshort](addr loc.value), cast[cshort](desired), exp16
      )
      let ok = prev == exp16
      if not ok:
        expected = cast[T](prev)
      ok
    elif sizeof(T) == 4:
      let exp32 = cast[int32](expected)
      let prev = msvcInterlockedCompareExchange32(
        cast[ptr clong](addr loc.value), cast[clong](desired), exp32
      )
      let ok = prev == exp32
      if not ok:
        expected = cast[T](prev)
      ok
    elif sizeof(T) == 8:
      let exp64 = cast[int64](expected)
      let prev = msvcInterlockedCompareExchange64(
        cast[ptr clonglong](addr loc.value), cast[clonglong](desired), exp64
      )
      let ok = prev == exp64
      if not ok:
        expected = cast[T](prev)
      ok
    else:
      {.error: "Atomic[T] vcc CAS supports only 1/2/4/8 byte T".}
  else:
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
  when defined(vcc):
    # MSVC `_InterlockedCompareExchange*` is always-strong (no spurious
    # failure) on x86_64. Weak ≡ Strong on vcc. Route to the strong
    # implementation rather than duplicate the body.
    compareExchangeStrong(loc, expected, desired, success, failure)
  else:
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
  when defined(vcc):
    when sizeof(T) == 1:
      cast[T](msvcInterlockedExchangeAdd8(
        cast[ptr cchar](addr loc.value), cast[cchar](v)
      ))
    elif sizeof(T) == 2:
      cast[T](msvcInterlockedExchangeAdd16(
        cast[ptr cshort](addr loc.value), cast[cshort](v)
      ))
    elif sizeof(T) == 4:
      cast[T](msvcInterlockedExchangeAdd32(
        cast[ptr clong](addr loc.value), cast[clong](v)
      ))
    elif sizeof(T) == 8:
      cast[T](msvcInterlockedExchangeAdd64(
        cast[ptr clonglong](addr loc.value), cast[clonglong](v)
      ))
    else:
      {.error: "Atomic[T] vcc fetchAdd supports only 1/2/4/8 byte T".}
  else:
    cast[T](atomicFetchAdd(
      cast[ptr nonAtomicType(T)](addr loc.value),
      cast[nonAtomicType(T)](v),
      toAtomMemModel(order),
    ))

proc fetchSub*[T: SomeInteger](
    loc: var Atomic[T], v: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  when defined(vcc):
    # MSVC has no _InterlockedExchangeSub; we emit fetchAdd of the
    # two's-complement negation. Works for signed and unsigned T because
    # the bit-level negation behavior is identical (uint8/16/32/64 are
    # cast through the matching signed int*).
    when sizeof(T) == 1:
      cast[T](msvcInterlockedExchangeAdd8(
        cast[ptr cchar](addr loc.value), -cast[cchar](v)
      ))
    elif sizeof(T) == 2:
      cast[T](msvcInterlockedExchangeAdd16(
        cast[ptr cshort](addr loc.value), -cast[cshort](v)
      ))
    elif sizeof(T) == 4:
      cast[T](msvcInterlockedExchangeAdd32(
        cast[ptr clong](addr loc.value), -cast[clong](v)
      ))
    elif sizeof(T) == 8:
      cast[T](msvcInterlockedExchangeAdd64(
        cast[ptr clonglong](addr loc.value), -cast[clonglong](v)
      ))
    else:
      {.error: "Atomic[T] vcc fetchSub supports only 1/2/4/8 byte T".}
  else:
    cast[T](atomicFetchSub(
      cast[ptr nonAtomicType(T)](addr loc.value),
      cast[nonAtomicType(T)](v),
      toAtomMemModel(order),
    ))

proc fetchAnd*[T: SomeInteger](
    loc: var Atomic[T], v: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  when defined(vcc):
    when sizeof(T) == 1:
      cast[T](msvcInterlockedAnd8(cast[ptr cchar](addr loc.value), cast[cchar](v)))
    elif sizeof(T) == 2:
      cast[T](msvcInterlockedAnd16(cast[ptr cshort](addr loc.value), cast[cshort](v)))
    elif sizeof(T) == 4:
      cast[T](msvcInterlockedAnd32(cast[ptr clong](addr loc.value), cast[clong](v)))
    elif sizeof(T) == 8:
      cast[T](msvcInterlockedAnd64(
        cast[ptr clonglong](addr loc.value), cast[clonglong](v)
      ))
    else:
      {.error: "Atomic[T] vcc fetchAnd supports only 1/2/4/8 byte T".}
  else:
    cast[T](atomicFetchAnd(
      cast[ptr nonAtomicType(T)](addr loc.value),
      cast[nonAtomicType(T)](v),
      toAtomMemModel(order),
    ))

proc fetchOr*[T: SomeInteger](
    loc: var Atomic[T], v: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  when defined(vcc):
    when sizeof(T) == 1:
      cast[T](msvcInterlockedOr8(cast[ptr cchar](addr loc.value), cast[cchar](v)))
    elif sizeof(T) == 2:
      cast[T](msvcInterlockedOr16(cast[ptr cshort](addr loc.value), cast[cshort](v)))
    elif sizeof(T) == 4:
      cast[T](msvcInterlockedOr32(cast[ptr clong](addr loc.value), cast[clong](v)))
    elif sizeof(T) == 8:
      cast[T](msvcInterlockedOr64(
        cast[ptr clonglong](addr loc.value), cast[clonglong](v)
      ))
    else:
      {.error: "Atomic[T] vcc fetchOr supports only 1/2/4/8 byte T".}
  else:
    cast[T](atomicFetchOr(
      cast[ptr nonAtomicType(T)](addr loc.value),
      cast[nonAtomicType(T)](v),
      toAtomMemModel(order),
    ))

proc fetchXor*[T: SomeInteger](
    loc: var Atomic[T], v: T, order: static MemoryOrder = moSequentiallyConsistent
): T {.inline.} =
  enforceAtomicConstraints(T)
  when defined(vcc):
    when sizeof(T) == 1:
      cast[T](msvcInterlockedXor8(cast[ptr cchar](addr loc.value), cast[cchar](v)))
    elif sizeof(T) == 2:
      cast[T](msvcInterlockedXor16(cast[ptr cshort](addr loc.value), cast[cshort](v)))
    elif sizeof(T) == 4:
      cast[T](msvcInterlockedXor32(cast[ptr clong](addr loc.value), cast[clong](v)))
    elif sizeof(T) == 8:
      cast[T](msvcInterlockedXor64(
        cast[ptr clonglong](addr loc.value), cast[clonglong](v)
      ))
    else:
      {.error: "Atomic[T] vcc fetchXor supports only 1/2/4/8 byte T".}
  else:
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
  when defined(vcc):
    # On vcc, moSeqCst emits the same hardware fence that
    # `MemoryBarrier` would expand to (`__faststorefence` on x86_64;
    # `__dmb(_ARM64_BARRIER_SY)` on ARM64) — but via `<intrin.h>`
    # primitives directly, avoiding a `<windows.h>` include. All weaker
    # orders map to a compile-only `_ReadWriteBarrier` because the
    # strong memory model of x86 (TSO) plus the locked semantics of
    # MSVC's `_Interlocked*` intrinsics means a hardware fence is only
    # required at seq_cst. On Windows-on-ARM64, MSVC's documented stance
    # is identical: `_InterlockedExchange`-family ops carry implicit dmb
    # semantics; only standalone seq_cst fences emit a bare dmb.
    case order
    of moSequentiallyConsistent:
      # Full hardware fence: `__faststorefence` on x86_64,
      # `__dmb(_ARM64_BARRIER_SY)` on aarch64, locked-or-on-dummy on
      # 32-bit x86 (where `__faststorefence` is not declared). All are
      # declared in `<intrin.h>` (already pulled in for the
      # `_Interlocked*` intrinsics) and are exactly what the
      # `MemoryBarrier` macro expands to — emitted directly to avoid
      # `<windows.h>` bloat and namespace pollution (gemini cycle-29).
      #
      # Dispatch is performed at the Nim level via `when` rather than
      # via C `#ifdef` inside `{.emit:.}`, because `{.emit:.}` does not
      # reliably place `#ifdef`/`#else`/`#endif` at column 0 inside a
      # function body — MSVC then rejects them with C2014 (gemini
      # cycle-34 CI blocker).
      when defined(arm64) or defined(aarch64):
        {.emit: ["__dmb(_ARM64_BARRIER_SY);"].}
      elif defined(i386) or defined(i686):
        # 32-bit MSVC: `__faststorefence` is x86_64-only. The standard
        # MSVC `MemoryBarrier` fallback on 32-bit is a `lock`-prefixed
        # `or` on a dummy stack slot — `_InterlockedOr(&_dummy, 0)`
        # carries full memory-barrier semantics on x86 by virtue of the
        # `lock` prefix (Intel SDM Vol. 3A §8.2.5).
        {.emit: ["{ long _dummy = 0; (void)_InterlockedOr(&_dummy, 0); }"].}
      else:
        {.emit: ["__faststorefence();"].}
    else:
      msvcReadWriteBarrier()
  else:
    atomicThreadFence(toAtomMemModel(order))

proc signalFence*(order: MemoryOrder) {.inline.} =
  ## Compiler-only fence. Prevents the compiler from reordering across
  ## the fence; emits no CPU instructions. All memory orders are valid.
  when defined(vcc):
    # `_ReadWriteBarrier` is the C-equivalent of GCC's
    # `__atomic_signal_fence` — it constrains the optimizer without
    # emitting any CPU instruction. Memory order is honored only as the
    # barrier strength expected of the compiler-side reordering; all
    # MSVC documentation treats `_ReadWriteBarrier` as the strongest
    # compile-only barrier. `order` is accepted but unused beyond the
    # barrier call (matching GCC's seq_cst-implicit behavior).
    discard order
    msvcReadWriteBarrier()
  else:
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
  when defined(vcc):
    # MSVC has no direct `_InterlockedTestAndSet`; canonical impl is
    # `_InterlockedExchange8(p, 1) != 0`. Returns whether the prior
    # byte was non-zero (i.e. flag was set). seq_cst at the hardware
    # level on x86_64; sub-seq_cst order accepted but not honored
    # beyond compile-barrier semantics implicit in the call.
    msvcInterlockedExchange8(cast[ptr cchar](addr loc), cchar(1)) != cchar(0)
  else:
    atomicTestAndSet(cast[pointer](addr loc), toAtomMemModel(order))

proc clear*(
    loc: var AtomicFlag, order: static MemoryOrder = moSequentiallyConsistent
) {.inline.} =
  ## Atomically reset the flag to false. `order` must not be
  ## moAcquire / moAcquireRelease / moConsume.
  validStoreOrder(order)
  when defined(vcc):
    # Atomic store of 0 via _InterlockedExchange8 (discard prior).
    discard msvcInterlockedExchange8(cast[ptr cchar](addr loc), cchar(0))
  else:
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
    ##
    ##
    ## vcc arm: `_InterlockedCompareExchange128` is guaranteed lock-free
    ## on every x86_64 Windows target (cmpxchg16b is mandatory in the
    ## platform ABI since Windows Vista, 2007) and on every ARM64 Windows
    ## target (casp under FEAT_LSE on ARMv8.1+, or LL/SC ldxp/stxp on
    ## ARMv8.0; both are MSVC-implemented internally). There is no
    ## equivalent of `__GCC_HAVE_SYNC_COMPARE_AND_SWAP_16` to gate on; the
    ## intrinsic is always present in <intrin.h>, so the vcc gate is
    ## vacuously satisfied at compile time and we elide the emit body.
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
    when defined(vcc):
      # vcc: _InterlockedCompareExchange128 is unconditionally available
      # in <intrin.h> on every Windows-on-AMD64 / Windows-on-ARM64 toolchain
      # we ship. No preprocessor predicate to gate on. (Distinction from
      # the GCC/Clang arm: `__GCC_HAVE_SYNC_COMPARE_AND_SWAP_16` is set
      # only when the active -m flags enable the underlying ISA; MSVC has
      # no equivalent because the intrinsic is always present and the
      # compiler emits the correct sequence (cmpxchg16b on x86_64, casp
      # /ldxp+stxp on ARM64) based on the active target without requiring
      # a -m flag.) Gate vacuously satisfied.
      discard
    elif defined(cpp):
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
    elif defined(vcc):
      # MSVC has no native 128-bit atomic load; canonical idiom is
      # `_InterlockedCompareExchange128(Dest, 0, 0, &Comparand)` with
      # Comparand initialized to zero. The function writes the current
      # *Dest into Comparand regardless of whether the swap succeeded
      # (per MS Learn, ComparandResult is always updated). The swap of
      # {0,0} over {0,0} is a no-op iff *Dest is already zero, and is
      # not performed otherwise (CAS fails). Either way, ComparandResult
      # ends up holding the atomically-observed prior value of *Dest.
      # MSDN: ComparandResult must be 16-byte aligned. `__declspec(align(16))`
      # on the stack array satisfies the requirement; misalignment raises a
      # GP fault on x64 and unaligned-access trap on ARM64.
      #
      # MSVC `_InterlockedCompareExchange128` is documented seq_cst on x64
      # (implicit `lock` prefix on `cmpxchg16b`) but only release-acquire
      # on ARM64 (it lowers to `caspal` or `ldaxp`/`stlxp`). On x64 the
      # `lock`-prefixed instruction is itself a full barrier per Intel
      # SDM Vol. 3A §8.2.5; flanking it with `_mm_mfence` adds real
      # latency (mfence is NOT a no-op next to lock-prefixed ops — the
      # earlier comment claim was wrong) without strengthening ordering.
      # We therefore emit `__dmb(_ARM64_BARRIER_SY)` only on ARM64 to
      # upgrade its release-acquire to seq_cst; on x64 the CAS alone
      # carries the full fence.
      {.
        emit: [
          "{ __declspec(align(16)) __int64 _cmp[2] = {0, 0};", "\n#ifdef _M_ARM64\n",
          "__dmb(_ARM64_BARRIER_SY);\n", "#endif\n",
          " (void)_InterlockedCompareExchange128((__int64 volatile *)", locPtr,
          ", 0, 0, _cmp);", "\n#ifdef _M_ARM64\n", "__dmb(_ARM64_BARRIER_SY);\n",
          "#endif\n", " memcpy(", resultPtr, ", _cmp, 16); }",
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
      # Explicit `(__int128)0` casts: bare `0` literal is `int` in C and
      # GCC may emit a sign-conversion warning (or implicit narrow) when
      # passed where `__int128` is expected by the typed builtin.
      {.
        emit: [
          "{ __int128 _new; __builtin_memcpy(&_new, ", desiredPtr,
          ", 16); __int128 _prev = __sync_val_compare_and_swap((__int128*)", locPtr,
          ", (__int128)0, (__int128)0); __int128 _ret;",
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
    elif defined(vcc):
      # MSVC has no native 128-bit atomic store; emit a CAS loop using
      # `_InterlockedCompareExchange128`. ComparandResult holds the prior
      # value seen each iteration; on failure MSVC writes the actual
      # current value back into ComparandResult, so the next iteration
      # retries with the freshest observation (mirroring the gcc arm's
      # `_prev = _ret` reuse). Loop terminates when CAS succeeds (return
      # value 1). CPU pause hint inside the retry loop: `_mm_pause` on
      # x86_64 (declared in <intrin.h>), `__yield` on ARM64 (also <intrin.h>);
      # both reduce cache-line bouncing under contention with zero cost
      # when uncontended. Dispatched via the MSVC predefines `_M_X64` /
      # `_M_ARM64`.
      # MSDN: ComparandResult must be 16-byte aligned. `__declspec(align(16))`
      # on the stack array satisfies the requirement; misalignment raises a
      # GP fault on x64 and unaligned-access trap on ARM64. (`_new` is only
      # decomposed into scalar ExchangeHigh/ExchangeLow args, so it does not
      # need alignment.)
      #
      # Upgrade `_InterlockedCompareExchange128` from release-acquire to
      # seq_cst on ARM64 via `__dmb(_ARM64_BARRIER_SY)`. On x64 the
      # `lock`-prefixed `cmpxchg16b` is itself a full memory barrier
      # (Intel SDM Vol. 3A §8.2.5), so explicit `_mm_mfence` adds
      # latency without strengthening ordering — emit fences on ARM64
      # only.
      {.
        emit: [
          "{ __int64 _new[2]; memcpy(_new, ", desiredPtr,
          ", 16); __declspec(align(16)) __int64 _cmp[2] = {0, 0};",
          "\n#ifdef _M_ARM64\n", "__dmb(_ARM64_BARRIER_SY);\n", "#endif\n",
          " (void)_InterlockedCompareExchange128((__int64 volatile *)", locPtr,
          ", 0, 0, _cmp);",
          " while (!_InterlockedCompareExchange128((__int64 volatile *)", locPtr,
          ", _new[1], _new[0], _cmp)) {\n", "#if defined(_M_X64)\n", "_mm_pause();\n",
          "#elif defined(_M_ARM64)\n", "__yield();\n", "#endif\n", " }",
          "\n#ifdef _M_ARM64\n", "__dmb(_ARM64_BARRIER_SY);\n", "#endif\n", " }",
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
      # Explicit `(__int128)0` casts: see dwcasStore for rationale.
      {.
        emit: [
          "{ __int128 _new; __builtin_memcpy(&_new, ", desiredPtr,
          ", 16); __int128 _prev = __sync_val_compare_and_swap((__int128*)", locPtr,
          ", (__int128)0, (__int128)0); __int128 _ret;",
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
    elif defined(vcc):
      # MSVC has no native 128-bit atomic exchange; emit a CAS loop
      # mirroring the gcc arm. Same pause-hint dispatch as dwcasStore.
      # `_cmp` holds the prior value seen each iteration; on CAS success
      # it carries the value that was atomically replaced (returned).
      # MSDN: ComparandResult must be 16-byte aligned. See dwcasLoad for
      # the alignment rationale; `_new` does not need it. Upgrade
      # release-acquire to seq_cst on ARM64 via `__dmb`; on x64 the
      # `lock`-prefixed `cmpxchg16b` is itself a full barrier (Intel
      # SDM Vol. 3A §8.2.5), so explicit `_mm_mfence` would only add
      # latency without strengthening ordering — emit fences on ARM64
      # only.
      {.
        emit: [
          "{ __int64 _new[2]; memcpy(_new, ", desiredPtr,
          ", 16); __declspec(align(16)) __int64 _cmp[2] = {0, 0};",
          "\n#ifdef _M_ARM64\n", "__dmb(_ARM64_BARRIER_SY);\n", "#endif\n",
          " (void)_InterlockedCompareExchange128((__int64 volatile *)", locPtr,
          ", 0, 0, _cmp);",
          " while (!_InterlockedCompareExchange128((__int64 volatile *)", locPtr,
          ", _new[1], _new[0], _cmp)) {\n", "#if defined(_M_X64)\n", "_mm_pause();\n",
          "#elif defined(_M_ARM64)\n", "__yield();\n", "#endif\n", " }",
          "\n#ifdef _M_ARM64\n", "__dmb(_ARM64_BARRIER_SY);\n", "#endif\n", " memcpy(",
          resultPtr, ", _cmp, 16); }",
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
    elif defined(vcc):
      # MSVC `_InterlockedCompareExchange128` is a true CAS: ComparandResult
      # is read as the expected value, the CAS is attempted, and on either
      # success or failure ComparandResult is overwritten with the current
      # *Dest. This matches the `__atomic_compare_exchange_n` contract on
      # the expected side: on failure the caller's `expected` is updated
      # with the observed value. Return value is 1 on success, 0 on failure
      # (-> result bool). Always-strong (no spurious failure on either
      # x86_64 or ARM64 — MSVC implements both natively and there's no
      # weak variant).
      # MSDN: ComparandResult must be 16-byte aligned. See dwcasLoad for
      # the alignment rationale; `_new` does not need it. Upgrade
      # release-acquire to seq_cst on ARM64 via `__dmb`; on x64 the
      # `lock`-prefixed `cmpxchg16b` is itself a full barrier (Intel
      # SDM Vol. 3A §8.2.5), so explicit `_mm_mfence` would only add
      # latency without strengthening ordering — emit fences on ARM64
      # only.
      {.
        emit: [
          "{ __declspec(align(16)) __int64 _cmp[2]; memcpy(_cmp, ", expectedPtr,
          ", 16); __int64 _new[2]; memcpy(_new, ", desiredPtr, ", 16);",
          "\n#ifdef _M_ARM64\n", "__dmb(_ARM64_BARRIER_SY);\n", "#endif\n", " ", result,
          " = (_InterlockedCompareExchange128((__int64 volatile *)", locPtr,
          ", _new[1], _new[0], _cmp) != 0);", "\n#ifdef _M_ARM64\n",
          "__dmb(_ARM64_BARRIER_SY);\n", "#endif\n", " memcpy(", expectedPtr,
          ", _cmp, 16); }",
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
    elif defined(vcc):
      # MSVC `_InterlockedCompareExchange128` has no weak variant —
      # always-strong on both x86_64 (cmpxchg16b) and ARM64 (MSVC emits
      # casp under FEAT_LSE or ldxp/stxp + retry under LL/SC, both
      # presented to the caller as always-strong). Weak ≡ Strong; emit
      # the same body as dwcasCasStrong.
      # MSDN: ComparandResult must be 16-byte aligned. See dwcasLoad for
      # the alignment rationale; `_new` does not need it. Upgrade
      # release-acquire to seq_cst on ARM64 via `__dmb`; on x64 the
      # `lock`-prefixed `cmpxchg16b` is itself a full barrier (Intel
      # SDM Vol. 3A §8.2.5), so explicit `_mm_mfence` would only add
      # latency without strengthening ordering — emit fences on ARM64
      # only.
      {.
        emit: [
          "{ __declspec(align(16)) __int64 _cmp[2]; memcpy(_cmp, ", expectedPtr,
          ", 16); __int64 _new[2]; memcpy(_new, ", desiredPtr, ", 16);",
          "\n#ifdef _M_ARM64\n", "__dmb(_ARM64_BARRIER_SY);\n", "#endif\n", " ", result,
          " = (_InterlockedCompareExchange128((__int64 volatile *)", locPtr,
          ", _new[1], _new[0], _cmp) != 0);", "\n#ifdef _M_ARM64\n",
          "__dmb(_ARM64_BARRIER_SY);\n", "#endif\n", " memcpy(", expectedPtr,
          ", _cmp, 16); }",
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
  # 16-byte componentwise fetch ops on `Atomic[Pair[A, B]]` where both
  # halves are integers. Implemented as CAS-loops on top of the 16-byte
  # `compareExchangeWeak` primitive — there is no native instruction for
  # 128-bit fetch-add (cmpxchg16b / casp are CAS-only); the CAS-loop is
  # the correct, zero-overhead-vs-handrolled lowering.
  #
  # Semantics: each op atomically replaces `(loc.first, loc.second)` with
  # `(loc.first OP delta.first, loc.second OP delta.second)` and returns
  # the prior pair. The two halves are updated as a single 128-bit atomic
  # transaction — no observer can see a `(new_first, old_second)` or
  # `(old_first, new_second)` half-state.
  #
  # `order` is applied to the SUCCESS path of the inner CAS; the failure
  # path uses `moRelaxed` (re-fetch + retry). The CAS-loop preserves
  # atomicity; under contention the loop may iterate multiple times.
  #
  # Push warning[User]: off across the block because the inner
  # `compareExchangeWeak` would otherwise emit the seq_cst-upgrade
  # warning when callers pass a sub-seq_cst `order`. The fetch* ops are
  # documented at the surface as "order applied to inner CAS success
  # path", so the upgrade is callable-visible and the warning is noise
  # at this layer.
  # -------------------------------------------------------------------------

  {.push warning[User]: off.}

  proc fetchAdd*[A, B: SomeInteger](
      loc: var Atomic[Pair[A, B]],
      delta: Pair[A, B],
      order: static MemoryOrder = moSequentiallyConsistent,
  ): Pair[A, B] {.inline.} =
    ## Atomically add `delta.first` to `loc.first` and `delta.second` to
    ## `loc.second`, returning the prior 128-bit pair. Both halves are
    ## updated as a single atomic transaction via a 16-byte CAS-loop
    ## (cmpxchg16b / casp / `_InterlockedCompareExchange128`).
    ##
    ## Wraparound matches the underlying integer half-type
    ## (`SomeInteger`): unsigned halves wrap modulo `2^(sizeof(half)*8)`;
    ## signed halves overflow per Nim signed-overflow rules.
    enforceDwcasConstraints(A, B)
    var prev = load(loc, moRelaxed)
    while true:
      let next =
        Pair[A, B](first: prev.first + delta.first, second: prev.second + delta.second)
      if compareExchangeWeak(loc, prev, next, order, moRelaxed):
        return prev

  proc fetchSub*[A, B: SomeInteger](
      loc: var Atomic[Pair[A, B]],
      delta: Pair[A, B],
      order: static MemoryOrder = moSequentiallyConsistent,
  ): Pair[A, B] {.inline.} =
    ## Componentwise atomic subtract. See `fetchAdd` for transactional
    ## semantics and overflow behavior.
    enforceDwcasConstraints(A, B)
    var prev = load(loc, moRelaxed)
    while true:
      let next =
        Pair[A, B](first: prev.first - delta.first, second: prev.second - delta.second)
      if compareExchangeWeak(loc, prev, next, order, moRelaxed):
        return prev

  proc fetchAnd*[A, B: SomeInteger](
      loc: var Atomic[Pair[A, B]],
      mask: Pair[A, B],
      order: static MemoryOrder = moSequentiallyConsistent,
  ): Pair[A, B] {.inline.} =
    ## Componentwise atomic bitwise AND. See `fetchAdd` for transactional
    ## semantics.
    enforceDwcasConstraints(A, B)
    var prev = load(loc, moRelaxed)
    while true:
      let next = Pair[A, B](
        first: prev.first and mask.first, second: prev.second and mask.second
      )
      if compareExchangeWeak(loc, prev, next, order, moRelaxed):
        return prev

  proc fetchOr*[A, B: SomeInteger](
      loc: var Atomic[Pair[A, B]],
      mask: Pair[A, B],
      order: static MemoryOrder = moSequentiallyConsistent,
  ): Pair[A, B] {.inline.} =
    ## Componentwise atomic bitwise OR. See `fetchAdd` for transactional
    ## semantics.
    enforceDwcasConstraints(A, B)
    var prev = load(loc, moRelaxed)
    while true:
      let next =
        Pair[A, B](first: prev.first or mask.first, second: prev.second or mask.second)
      if compareExchangeWeak(loc, prev, next, order, moRelaxed):
        return prev

  proc fetchXor*[A, B: SomeInteger](
      loc: var Atomic[Pair[A, B]],
      mask: Pair[A, B],
      order: static MemoryOrder = moSequentiallyConsistent,
  ): Pair[A, B] {.inline.} =
    ## Componentwise atomic bitwise XOR. See `fetchAdd` for transactional
    ## semantics.
    enforceDwcasConstraints(A, B)
    var prev = load(loc, moRelaxed)
    while true:
      let next = Pair[A, B](
        first: prev.first xor mask.first, second: prev.second xor mask.second
      )
      if compareExchangeWeak(loc, prev, next, order, moRelaxed):
        return prev

  {.pop.}

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
