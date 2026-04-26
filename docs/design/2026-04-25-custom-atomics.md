# Custom Atomics Module for nim-debra (and lockfreequeues)

Status: Draft. Author: project maintainer. Date: 2026-04-25.

## 1. Motivation

`std/atomics` silently spinlocks non-`Trivial` `T`; `Atomic[ref T]` is therefore not lock-free under arc/orc and contributors keep tripping (`unbounded_sipsic.nim:56`, `unbounded_mupsic.nim:101`, `convenience.nim:56`, `managed.nim:16`). Generic `sizeof(Atomic[T])` also doesn't propagate without compiler help (Nim PR 25480). We want to ship without waiting.

A small module owns the ops we use, rejects `ref T` at compile time, never silently spinlocks. Lives in nim-debra; re-exported from a lockfreequeues shim during migration.

## 2. API Surface

```nim
type
  MemoryOrder* = enum
    # Ordinals match GCC's __ATOMIC_* (RELAXED=0, CONSUME=1, ACQUIRE=2,
    # RELEASE=3, ACQ_REL=4, SEQ_CST=5) so `ord(order)` is passed directly.
    moRelaxed
    moConsume         # accepted, mapped to moAcquire (see section 5)
    moAcquire
    moRelease
    moAcquireRelease
    moSequentiallyConsistent

  Atomic*[T] = object
    # T constrained via `when T is ref: {.error.}` plus
    # `when not supportsCopyMem(T): {.error.}` (section 4). No concept
    # needed. Atomic[T] is required to be lock-free at compile time
    # (section 3.1).
    # `value` is `{.align: max(alignof(T), sizeof(T)).}` so the operand is
    # naturally aligned regardless of containing-struct layout (section 3.2).
    # `static: assert alignof(Atomic[T]) >= sizeof(T)` guards the type.
    value {.align: alignofAtomic(T).}: T

  AtomicFlag* = distinct uint8
    ## Underlying byte must be 0 or 1; `__atomic_test_and_set` is
    ## implementation-defined for any other value.

# Loads / stores
proc load*[T](loc: var Atomic[T]; order = moSequentiallyConsistent): T {.inline.}
proc store*[T](loc: var Atomic[T]; desired: T; order = moSequentiallyConsistent) {.inline.}

# Read-modify-write
proc exchange*[T](loc: var Atomic[T]; desired: T; order = moSequentiallyConsistent): T {.inline.}
proc compareExchange*[T](loc: var Atomic[T]; expected: var T; desired: T;
                         success, failure: MemoryOrder): bool {.inline.}
proc compareExchange*[T](loc: var Atomic[T]; expected: var T; desired: T;
                         order = moSequentiallyConsistent): bool {.inline.}
proc compareExchangeWeak*[T](loc: var Atomic[T]; expected: var T; desired: T;
                             success, failure: MemoryOrder): bool {.inline.}
proc compareExchangeWeak*[T](loc: var Atomic[T]; expected: var T; desired: T;
                             order = moSequentiallyConsistent): bool {.inline.}

# Numeric (SomeInteger)
proc fetchAdd*[T: SomeInteger](loc: var Atomic[T]; v: T; order = moSequentiallyConsistent): T {.inline.}
proc fetchSub*[T: SomeInteger](loc: var Atomic[T]; v: T; order = moSequentiallyConsistent): T {.inline.}
proc fetchAnd*[T: SomeInteger](loc: var Atomic[T]; v: T; order = moSequentiallyConsistent): T {.inline.}
proc fetchOr*[T: SomeInteger](loc: var Atomic[T]; v: T; order = moSequentiallyConsistent): T {.inline.}
proc fetchXor*[T: SomeInteger](loc: var Atomic[T]; v: T; order = moSequentiallyConsistent): T {.inline.}

# AtomicFlag
proc testAndSet*(loc: var AtomicFlag; order = moSequentiallyConsistent): bool {.inline.}
proc clear*(loc: var AtomicFlag; order = moSequentiallyConsistent) {.inline.}

# Fences
proc threadFence*(order: MemoryOrder) {.inline.}
proc signalFence*(order: MemoryOrder) {.inline.}

# Cache-line alignment helpers (owned here; see below)
const CacheLineBytes* {.intdefine.} = when defined(powerpc): 128 else: 64
template cacheLineAligned*(decl: untyped) =
  ## Drop-in `{.align: CacheLineBytes.}` shorthand.
```

**Operations used today.** `types.nim` and `signal.nim` use `Atomic[uint64|bool|ThreadId]` `load`/`store` (acquire/release/relaxed). `debra.nim` and `typestates/advance.nim` use `fetchAdd(.., moRelease)`. `typestates/registration.nim` uses `compareExchangeWeak(.., moRelease, moAcquire)`. lockfreequeues uses `compareExchange` heavily and `Atomic[ptr Segment[S, T]]`. Zero call sites for `exchange`, `fence`, `signalFence`, `fetchAnd/Or/Xor`, `AtomicFlag`. They cost little to include.

**`compareExchange*` failure semantics.** Matches `__atomic_compare_exchange_n` and `std/atomics`: on failure, `expected` is updated in place to the current value of `loc`. Supports the standard CAS loop where `expected` reseeds from the latest observation on each spin.

**Cache-line alignment.** `CacheLineBytes` lives in `debra/atomics`; both libs import it. Preserves PowerPC case (`128`/`64`), stays `{.intdefine.}`. `cacheLineAligned` is sugar over `{.align: CacheLineBytes.}`.

**DSL (`.relaxed/.acquire/.release/.sequential`).** Symmetric: `head.relaxed()` loads, `head.relaxed(value)` stores. Mirrors lockfreequeues `atomic_dsl.nim`. Lives in the optional `debra/atomics/dsl` submodule, not the core. `compareExchange` stays out of the DSL.

## 3. Implementation Strategy

**Recommendation: Option (b) — wrap GCC/Clang `__atomic_*` builtins on a plain Nim object, MSVC fallback for VC.**

```
type Atomic*[T] = object
  value: T
```

Mirrors `std/atomics`'s C path (`atomics.nim:317-326`) without the `_Atomic NIxx` typedef. `__atomic_*_n` builtins work on plain memory of suitable size/alignment with a runtime memory-order argument; no `<stdatomic.h>` needed.

Tradeoff vs. (a) C11 `_Atomic` via `importc + size: sizeof(T)`: cleaner types but PR 25480 territory — generic `sizeof` is unreliable until it merges. Storing `T` directly gives `sizeof(Atomic[T]) == sizeof(T)` for free. Tradeoff vs. (c) Nim's `system.atomicLoadN`: same builtins, partly undocumented, varies across Nim versions; one explicit `{.importc.}` per op is cleaner.

MSVC: replicate `_Interlocked*` from `atomics.nim:212-276` (~80 lines). `threadFence(order)` → `__atomic_thread_fence(ord(order))`; `signalFence(order)` → `__atomic_signal_fence(ord(order))`.

### 3.1 Lock-Free Enforcement

Every `Atomic[T]` must be lock-free. Checked via `__atomic_always_lock_free(sizeof(T), 0)` (GCC/Clang) and `_InterlockedCompareExchange*`-size dispatch (MSVC), wrapped behind `template isAlwaysLockFree(T: typedesc): bool` in a `static:` block. Fires at type definition; non-lock-free fails at the use site. Because `value` is force-aligned to `sizeof(T)` (§3.2), `__atomic_always_lock_free` is not misled by 32-bit targets that would default-align `Atomic[uint64]` to 4 bytes.

```
Atomic[T] is not lock-free on this target. Use a smaller T, or pass
-d:debraAllowNonLockFreeAtomics if you understand the implications.
```

`-d:debraAllowNonLockFreeAtomics` is the opt-out, mirroring lockfreequeues' `-d:allowNonLockFreeQueueItems`. When defined, the static check is skipped and ops dispatch to generic library forms (`__atomic_load`, `__atomic_store`, `__atomic_compare_exchange` non-`_n`), which spinlock via libatomic if hardware support is missing. A `{.warning: "Atomic[T] is not lock-free on this target; using libatomic spinlock fallback".}` fires at the call site. Tests assert negative (default rejects) and positive (flag passes + warning fires) cases. Default is strict.

### 3.2 Alignment

`value` is `{.align: alignofAtomic(T).}` where `alignofAtomic(T) == max(alignof(T), sizeof(T))` for primitives up to pointer width. The operand is naturally aligned regardless of outer-struct layout — critical on 32-bit targets where `Atomic[uint64]` would default-align to 4 bytes and silently lose the lock-free guarantee `__atomic_always_lock_free(8, 0)` reports. `static: assert alignof(Atomic[T]) >= sizeof(T)` guards the type. If a caller embeds `Atomic[T]` in `{.packed.}`, Nim rejects the alignment override — caller's problem.

### 3.3 Memory Order Validation

Each op rejects illegal `MemoryOrder` at compile time via a `static:` / `when` guard, mirroring C11:

- `store`: forbids `moAcquire`, `moAcquireRelease`, `moConsume`.
- `load`: forbids `moRelease`, `moAcquireRelease`.
- `compareExchange*` two-order form: `failure` cannot be `moRelease` or `moAcquireRelease`, and must not be stronger than `success` (ordinal comparison).
- `threadFence` / `signalFence`: any order accepted (`moConsume` is allowed but useless).

Errors fire verbatim at the call site:

```
Error: moAcquire is not a valid memory order for store; use moRelaxed,
moRelease, or moSequentiallyConsistent

Error: compareExchange failure order moAcquireRelease is stronger than
success order moAcquire; failure must be <= success and must not be
moRelease or moAcquireRelease
```

## 4. `T` Constraint and `ref T` Handling

**Two compile-time gates, no concept.**

1. `when T is ref: {.error: "Atomic[ref T] is forbidden. Use Managed[T] (see debra/managed) or Atomic[ptr T] for raw pointers.".}`. Targeted message for the most common footgun.
2. `when not supportsCopyMem(T): {.error: "Atomic[T] requires T to be trivially copyable (no GC-managed fields). For ref types, use Managed[T] or Atomic[ptr T].".}`. Catches any type whose representation transitively includes GC-managed fields (`seq`, `string`, object with a `ref` field).

`supportsCopyMem` (`std/typetraits`) is exactly Nim's "can `copyMem` this safely" predicate, which is what `__atomic_*_n` does under the hood. The C-level `_Static_assert(__atomic_always_lock_free(sizeof(T), 0), ...)` is the second gate.

Together they admit primitive integers, `ptr`/`pointer`, `bool`, `char`, `enum`, `distinct` types over any of the above, and POD `object` types like `ThreadId` (wraps `Pthread`) provided natural alignment is at least size and the lock-free builtin accepts the size. Refs, seqs, strings, and objects with transitive GC fields are rejected. Largest UX win over `std/atomics`: warnings in `unbounded_*.nim:56,98,101,106` / `convenience.nim:56` become a clear compile error. `Managed[T]` dodges the `=destroy`/cycle-collection/refcount swamp.

A strict whitelist would reject `Atomic[ThreadId]` and force wrappers to `distinct uint64`. `supportsCopyMem` is the right predicate; lock-free static assert rejects oversized PODs.

## 5. Memory Order Naming

**Keep `moRelaxed/moConsume/moAcquire/moRelease/moAcquireRelease/moSequentiallyConsistent`.** Matches std, every existing call site (50+ in lockfreequeues, 20+ in nim-debra), and the C/C++ standard. Migration is a mechanical import sweep. `moConsume` is documented as "accepted; treated as `moAcquire`" — matches what every real compiler does.

## 6. Migration Plan

1. Land `src/debra/atomics.nim` with the API (§2), implementation (§3), `T` constraint and lock-free check (§4 / 3.1), and tests against `std/atomics` semantics for the trivial types we use.
2. Migrate nim-debra internals file-by-file: `types.nim`, `signal.nim`, `debra.nim`, `typestates/{registration,guard,advance,reclaim,neutralize,manager}.nim`. Each PR is a one-line import change.
3. Add `export atomics` from the top-level `debra` module.
4. In lockfreequeues: rewrite `atomic_dsl.nim` to `import debra/atomics/dsl; export ...`, drop `CacheLineBytes` from `src/lockfreequeues/constants.nim` (re-import from `debra/atomics`), and replace every `import [std/]atomics` with `import debra/atomics`.
5. Test suite in `tests/atomics/`: load/store all orderings, CAS strong+weak (both success/failure orderings), fetch{Add,Sub,And,Or,Xor}, ABA on `ptr T`, AtomicFlag, fences, `static` rejection of `Atomic[ref T]`, `static` rejection of non-lock-free `Atomic[T]` (with `-d:debraAllowNonLockFreeAtomics` flipping rejection to pass + warning), and the §3.3 illegal-memory-order rejections.
6. CI matrix: refc, arc, orc; `--threads:{on,off}`; gcc and clang on Linux + macOS, MSVC if reachable.

## 7. Open Questions

Resolved as of 2026-04-25.

## 8. Non-Goals

- Replacing `std/atomics` upstream. Scratching our own itch.
- C++ atomics interop / `nimUseCppAtomics` parity. C target only.
- A general "atomic anything" facility. Explicit: `supportsCopyMem` PODs and lock-free sized, `ptr T`, no `ref T`.
- `Atomic[T]` for `T` larger than the platform's lock-free word (DCAS / 128-bit). Separate design doc if needed.
- Wrapping every Nim builtin (`atomicInc`, `+=`, `-=`). Sugar later; core stays minimal.
- A `CacheLinePadded[T]` wrapper. Use `{.align: CacheLineBytes.}` directly; revisit if pervasive.
- MSVC ARM64 with full memory-order fidelity. MSVC fallback targets x86/x64 only in v1; ARM64-on-Windows needs `_Interlocked*_acq`/`_rel`/`_nf` variants when a consumer needs them. Project targets: macOS arm64 + Linux.
