# Atomics

`debra/atomics` is nim-debra's custom atomics module. It exists alongside —
and intentionally diverges from — `std/atomics`. This guide explains *why*
the module exists, what it offers over `std/atomics`, and when you should
(or shouldn't) reach for it.

If you only ever need 1/2/4/8-byte atomics with sequentially-consistent
ordering and you trust your platform, `std/atomics` is fine. The rest of
this guide is for callers who need stronger compile-time guarantees,
DWCAS (16-byte CAS), or LCRQ-style algorithms.

## 1. Why a separate module exists

`debra/atomics` is *not* a thin wrapper around `std/atomics`. It is a
parallel implementation that hard-bakes four invariants `std/atomics`
either lacks or enforces only at runtime. See the module preamble
(`src/debra/atomics.nim` lines 1–25) for the canonical version of this
list:

1. **Reject `Atomic[ref T]` at compile time.** `std/atomics` silently
   accepts a GC-managed `ref` payload and falls back to a non-lock-free
   spinlock object. `debra/atomics` refuses to compile in that case and
   directs you to `Atomic[ptr T]` plus `retain` / `releaseDestructor`
   from `debra/refptr`.
2. **Require `Atomic[T]` to be lock-free at compile time.** A
   `static assert` on `__atomic_always_lock_free` fails the build on
   any target where the underlying op would synthesize a lock. No
   silent downgrade to a spinlock object.
3. **Validate `MemoryOrder` per op at compile time.** Passing a
   release-class order to a pure load (or an acquire-class order to a
   pure store) is a compile error, not a runtime contract you have to
   remember.
4. **Statically assert `alignof(Atomic[T]) >= sizeof(T)`.** This catches
   under-aligned types (e.g. `uint64` on a 32-bit ABI whose natural
   alignment is 4 bytes) at the build, not on first cache-line straddle
   in production.

For the v0.10.0 release, `debra/atomics` adds a fifth invariant — DWCAS
(16-byte / 128-bit atomics) as `Atomic[Pair[A, B]]`. That capability
does not exist in `std/atomics` at all, and is the proximate reason
nim-debra ships its own atomics module rather than re-exporting the
standard one.

## 2. Side-by-side with `std/atomics`

| Feature                              | `std/atomics`                                                       | `debra/atomics`                                                                  |
| ------------------------------------ | ------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `Atomic[ref T]`                      | Silently accepted, becomes a spinlock object                        | **Compile error** with remediation hint                                          |
| Non-lock-free `Atomic[T]`            | Allowed, runs as a spinlock object                                  | **Compile error** (gate 2)                                                       |
| Bad `MemoryOrder` per op             | Allowed; std accepts release on a load, etc.                        | **Compile error**: `validLoadOrder` / `validStoreOrder` / `validCasFailureOrder` |
| Under-aligned `Atomic[T]`            | Allowed; depends on the natural alignment of `T`                    | **Compile error**: `alignof(Atomic[T]) >= sizeof(T)` is asserted                 |
| 16-byte atomics (DWCAS)              | Not supported                                                       | `Atomic[Pair[A, B]]` with load/store/exchange/compareExchange{Strong,Weak}       |
| Per-callsite memory-order relaxation | N/A                                                                 | `dwcasOrderRelaxedCAS:` template                                                 |
| MSVC                                 | Supported                                                           | Supported (full `Atomic[T]` surface + DWCAS via `_InterlockedCompareExchange128`) |
| 32-bit targets                       | Supported                                                           | Supported for ≤8 bytes; **DWCAS rejected** at compile time on 32-bit ABIs        |

### Concrete: the silent-spinlock footgun

```nim
import std/atomics

type Big = object
  data: array[6, uint64]   # 48 bytes — way too wide to be lock-free

var x: Atomic[Big]   # std/atomics: compiles. Becomes a spinlock object.
                     # No warning, no error. You get a mutex disguised
                     # as an atomic, with all the latency that implies.
```

```nim
import debra/atomics

type Big = object
  data: array[6, uint64]

var x: Atomic[Big]   # debra/atomics: COMPILE ERROR
#                      "Atomic[Big] is not lock-free on this target..."
#                      "Pass -d:CacheLineBytes=... if your platform..."
```

The `debra/atomics` form fails the build and tells you what to fix. The
`std/atomics` form ships a hidden contention pile.

## 3. What you get in v0.10.0 that `std/atomics` doesn't

v0.10.0 adds DWCAS — 16-byte / 128-bit atomic compare-and-swap and the
load/store/exchange ops that go with it. The surface is:

| Symbol                                    | Purpose                                                                              |
| ----------------------------------------- | ------------------------------------------------------------------------------------ |
| `Pair[A, B]`                              | 16-byte-aligned object with fields `first: A`, `second: B`. The DWCAS cell type.     |
| `Atomic[Pair[A, B]]`                      | Atomic over a 16-byte pair. Requires a 64-bit target and arch-specific compile flags. |
| `load` / `store` / `exchange`             | 16-byte ops on `Atomic[Pair[A, B]]`. Always seq_cst at the instruction level.        |
| `compareExchangeStrong` (3 overloads)     | Strong 16-byte CAS. `(success, failure)`, single-order, and default-order forms.     |
| `compareExchangeWeak` (3 overloads)       | Weak 16-byte CAS. `(success, failure)`, single-order, and default-order forms. May fail spuriously only on ARMv8.0 LL/SC; equivalent to Strong elsewhere. See §5.   |
| `compareExchange` aliases (3 overloads)   | Unsuffixed-name aliases routing to `compareExchangeStrong`, for `std/atomics`-style spelling. |
| `fetchAdd` / `fetchSub` / `fetchAnd` / `fetchOr` / `fetchXor` | 16-byte componentwise atomic RMW on `Atomic[Pair[A, B]]` where `A, B: SomeInteger`. Both halves updated as a single 128-bit transaction via a CAS-loop (cmpxchg16b / casp / `_InterlockedCompareExchange128` is CAS-only — there is no native 128-bit fetch instruction). |
| `dwcasOrderRelaxedCAS:`                   | Template that wraps a single call site to suppress the seq_cst-upgrade warning.      |

In addition, v0.10.0 ships CI infrastructure that `std/atomics` does not
and cannot reasonably provide on its own:

- **Cross-compiler macro probe.** Before any DWCAS test runs, CI verifies
  that the C compiler defines `__GCC_HAVE_SYNC_COMPARE_AND_SWAP_16` (or
  the arch equivalent) on every supported (compiler × OS × arch) cell.
- **`objdump` regex check.** After compilation, CI disassembles the
  binary and confirms the emit really inlined to `cmpxchg16b` (x86_64)
  or `casp` / `caspal` (arm64). No silent fallback to a library call.
- **Compile-time error with exact-flag hint.** When the build is missing
  `-mcx16` (gcc x86_64) or `-march=armv8.1-a+lse -mno-outline-atomics`
  (gcc arm64), the error message names the missing flag — you don't
  have to triage a generic "lock-free not available" message.

## 4. When NOT to use `debra/atomics`

Don't reach for this module just because nim-debra uses it. Concrete
"`std/atomics + Lock` is the simpler answer" cases:

- **You don't need lock-free guarantees.** A single mutex around a
  shared mutable struct is dramatically easier to reason about than a
  hand-rolled CAS loop. Reach for `Lock` first.
- **You're on a compiler that isn't gcc / clang / llvm_gcc /
  nintendoswitch / vcc (MSVC).** `debra/atomics` errors out at import
  time on unsupported toolchains. v0.10.0 adds full MSVC support; the
  vcc arms route to `_InterlockedCompareExchange*` for 1/2/4/8 byte ops
  and `_InterlockedCompareExchange128` for DWCAS. Other backends (tcc,
  bcc, etc.) remain unsupported.
- **You're on a 32-bit ABI and want 16-byte atomics.** DWCAS requires a
  64-bit target. The 32-bit ABI fails gate 1 (`sizeof(pointer) == 8`)
  at compile time.
- **You want fetch-and-add on a 16-byte cell where the halves are not
  integers.** The 16-byte `fetchAdd` / `fetchSub` / `fetchAnd` / `fetchOr`
  / `fetchXor` ops require both halves to be `SomeInteger`. Floats or
  pointer halves are not supported (bitwise ops have no meaningful
  semantics on floats; arithmetic on pointer halves likewise). Use
  `compareExchange*` directly for non-integer pair payloads.
- **You want a portable `std/atomics`-shaped surface across all Nim
  targets.** Use `std/atomics`. `debra/atomics` is intentionally narrower.

## 5. Memory-order policy

`debra/atomics` validates memory orders at compile time. The rules:

| Op family                              | Allowed orders                                                          |
| -------------------------------------- | ----------------------------------------------------------------------- |
| `load`                                 | `moRelaxed`, `moConsume`, `moAcquire`, `moSequentiallyConsistent`       |
| `store`                                | `moRelaxed`, `moRelease`, `moSequentiallyConsistent`                    |
| `exchange`                             | Any                                                                     |
| `compareExchange*` (success)           | Any                                                                     |
| `compareExchange*` (failure)           | Must be a load-class order, must not be stronger than success; when `success == moRelease`, `failure` MUST be `moRelaxed` (see below) |
| Any DWCAS op (16-byte) at the instruction level | Always `moSequentiallyConsistent` regardless of what you pass |

### C11-strict failure-order validity

Per C11 §7.17.7.4, the failure order of a `compareExchange` is the load
order taken on the failed CAS path. It must satisfy:

- `failure != moRelease` (failure is a pure load; loads cannot release).
- `failure != moAcquireRelease` (same reason).
- `failure` cannot be stronger than the load component of `success`.

The third rule is *stricter* than the naive `ord(failure) <= ord(success)`
comparison. In particular, when `success == moRelease`, `failure` MUST be
`moRelaxed`. `moRelease` has no load-acquire on the success path, so the
failure path (which is a pure load) cannot acquire either —
`success=moRelease, failure=moAcquire` is invalid even though
`ord(moAcquire) <= ord(moRelease)` numerically.

nim-debra v0.10.0 enforces this at compile time via `validCasFailureOrder`
(`src/debra/atomics.nim`). The LCRQ producer publish (the canonical
release/relaxed use case) passes `moRelease`/`moRelaxed` and is accepted;
mixing `moRelease`/`moAcquire` is rejected with a compile-time
`assert` that names the offending pair.

### The DWCAS seq_cst upgrade

All 16-byte ops emit seq_cst at the C / machine level. This is a
deliberate choice driven by the gcc-x86_64 `__sync_*` legacy: those
builtins do not take a memory-order argument and behave as seq_cst.
Rather than expose a per-backend asymmetry (clang and arm64 *can* take
sub-seq_cst orders), v0.10.0 normalizes to seq_cst everywhere.

When you pass a sub-seq_cst order to a 16-byte op, you get a compile-
time warning at every call site:

```
nim-debra DWCAS upgrades memory order to moSequentiallyConsistent at the
instruction level. Pass moSequentiallyConsistent to silence this warning,
or wrap the call site in `dwcasOrderRelaxedCAS:` if the relaxation is
intentional.
```

If the relaxation is audited and intentional (notably: the LCRQ producer
publish CAS, which mathematically wants `moRelease` / `moRelaxed`), wrap
just that call site:

```nim
dwcasOrderRelaxedCAS:
  discard cell.compareExchangeStrong(expected, desired, moRelease, moRelaxed)
```

The warning continues to fire at every unwrapped call site. The wrap is
per-site, not per-module — you can't accidentally silence the warning
globally.

### When to use Strong vs Weak compareExchange

The Strong/Weak distinction matters only on ARMv8.0 cores that use the
LL/SC primitives `ldaxp` / `stlxp`. On all other supported targets the
two are equivalent in both cost and behaviour:

- **x86_64 (gcc and clang).** Both `compareExchangeStrong` and
  `compareExchangeWeak` lower to `cmpxchg16b`, which is always-strong.
  The `weak` flag is a no-op.
- **arm64 with FEAT_LSE / LSE2 (Apple Silicon, modern server chips).**
  Both lower to `caspal` (single-instruction CAS). The `weak` flag is a
  no-op. Verified by `objdump` of a release-mode probe on Apple Silicon:
  both procs emit identical `caspal` instructions, no `ldaxp` / `stlxp`
  pairs are emitted on either path. Empirical measurement under pure
  contention on Apple Silicon (cycle-13 CI run): the
  `compareExchangeWeak` failure rate matches `compareExchangeStrong`
  exactly (13.86% real contention loss on the measured workload, 0%
  spurious-failure delta). The Strong/Weak distinction collapses on
  this microarchitecture.
- **arm64 ARMv8.0 (LL/SC fallback, e.g. Raspberry Pi 3, Cortex-A53).**
  Weak uses `ldaxp` / `stlxp` and is permitted to fail spuriously;
  Strong wraps the LL/SC pair in a retry loop.

Practical guidance:

- **Default to Strong** on all targets. It is the safer choice (no
  spurious-failure branch to handle) and equivalent cost on every
  target v0.10.0 explicitly supports (CI cells are x86_64 and
  Apple-Silicon-equivalent ARMv8.1+).
- **Use Weak only if** you have measured your specific workload and
  chip and confirmed (a) Strong is showing CAS-loop overhead from
  contention, AND (b) your target is ARMv8.0 LL/SC, AND (c) the
  surrounding loop already reloads `expected` on the failure path.

The unsuffixed-name aliases `compareExchange` route to Strong, matching
the `std/atomics` default. Weak must be spelled out explicitly.

## 6. Compatibility matrix

### Supported compilers

| Compiler       | Supported     | Notes                                                                      |
| -------------- | ------------- | -------------------------------------------------------------------------- |
| gcc            | Yes           | DWCAS via `__sync_val_compare_and_swap` on `__int128`. Requires `-mcx16` on x86_64 (shipped via nim.cfg); requires `-march=armv8.1-a+lse -mno-outline-atomics` on aarch64. |
| clang          | Yes           | DWCAS via `__atomic_compare_exchange_n` on `__int128`. Inlines `cmpxchg16b` on x86_64 under `-mcx16`; inlines `caspal` on aarch64 under default LSE (Apple Silicon native, Linux ARM requires `-march=armv8.1-a+lse`). |
| llvm_gcc       | Yes           | Treated as clang-shape (`__atomic_*` path)                                 |
| nintendoswitch | Accepted      | Treated as clang-shape (`__atomic_*` path)                                 |
| vcc (MSVC)     | Yes (x64 and ARM64 seq_cst) | Full `Atomic[T]` surface via `_Interlocked*` intrinsics family (`<intrin.h>`); DWCAS via `_InterlockedCompareExchange128`. No `-m`-style flags required — MSVC always emits `cmpxchg16b` on x86_64 / `casp`+LL/SC on ARM64. The DWCAS comparand array is declared `__declspec(align(16)) __int64 _cmp[2]` (load-bearing: MSDN requires 16-byte alignment for `_InterlockedCompareExchange128`'s `ComparandResult` parameter). DWCAS sites wrap the intrinsic with a full hardware fence before and after to upgrade MSVC's default release-acquire to seq_cst: `_mm_mfence()` on x64, `__dmb(_ARM64_BARRIER_SY)` on ARM64. ARM64 Windows is not in the v0.10.0 CI matrix (windows-2022 x64 only) but the dispatch is symmetric. |

### Supported architectures (for DWCAS)

Dispatch is by **compiler**, not architecture. Three arms cover both x86_64
and aarch64:

- **GCC (any arch)**: `__sync_val_compare_and_swap` on `__int128`. Required
  because GCC's `__atomic_*_n` family at 16 bytes silently falls back to
  `libatomic` (`__atomic_load_16`, `__atomic_compare_exchange_16`, etc.) on
  BOTH x86_64 (regardless of `-mcx16`) AND aarch64 (regardless of LSE flags) —
  only the legacy `__sync_*` builtins reliably inline to `cmpxchg16b` /
  `casp` under GCC.
- **Clang / llvm_gcc / nintendoswitch (any arch)**: `__atomic_compare_exchange_n`
  on `__int128`. Clang's `__atomic_*` family inlines correctly under `-mcx16`
  (x86_64) or default LSE (aarch64).
- **vcc (MSVC) (x86_64 or ARM64)**: `_InterlockedCompareExchange128` from
  `<intrin.h>`. The intrinsic is guaranteed lock-free on every Windows-on-AMD64
  target (cmpxchg16b is mandatory in the platform ABI since Windows Vista) and
  Windows-on-ARM64 target (MSVC emits `casp` under FEAT_LSE or LL/SC otherwise).
  load/store/exchange synthesize from `_InterlockedCompareExchange128` (no native
  128-bit load/store/exchange on MSVC). The 1/2/4/8-byte surface uses the
  `_Interlocked*` family directly (`_InterlockedExchange*` / `_InterlockedCompareExchange*`
  / `_InterlockedExchangeAdd*` / `_InterlockedAnd|Or|Xor*`); see Phase B in
  `src/debra/atomics.nim` for the full importc binding table.
  - **Comparand alignment (load-bearing).** MSDN requires the
    `ComparandResult` parameter of `_InterlockedCompareExchange128` to be
    16-byte aligned. Each of the 5 DWCAS emit sites declares the local
    comparand array as `__declspec(align(16)) __int64 _cmp[2]`; dropping
    that pragma is undefined behavior per MSDN and would silently
    miscompare on platforms that enforce alignment (ARM64 in particular).
  - **Full hardware fence wrap for seq_cst.** MSVC's `_Interlocked*`
    intrinsics document only release-acquire semantics by default
    (x86 hardware happens to give seq_cst for `lock cmpxchg16b`, but
    the *intrinsic's contract* is release-acquire). To match
    `std/atomics` Sequentially Consistent semantics, DWCAS sites
    bracket the intrinsic with a full hardware fence on both sides
    of the CAS: `_mm_mfence()` (from `<intrin.h>`) on x64,
    `__dmb(_ARM64_BARRIER_SY)` on ARM64 Windows. Dispatch is by the
    MSVC predefine `_M_ARM64` via a `#ifdef` inside the emit body.
    `_mm_mfence` lowers to `mfence` on x86; `__dmb _SY` lowers to
    `dmb sy` on ARM64. Both give full system-domain ordering, lifting
    the intrinsic from release-acquire to seq_cst on both architectures.
  - **ARM64 Windows CI coverage.** ARM64 Windows (Snapdragon X+,
    Windows-on-ARM) is not in the v0.10.0 CI matrix (windows-2022 x64
    only). The emit dispatch is symmetric (`#ifdef _M_ARM64` selects
    `__dmb`); the surface is identical to x64 from a callsite
    perspective. PR welcome on regressions.

| Arch                 | Supported     | Required compiler flag                                                                                          |
| -------------------- | ------------- | --------------------------------------------------------------------------------------------------------------- |
| x86_64 (amd64)       | Yes           | `-mcx16` (both gcc and clang). MSVC: no flag required (`_InterlockedCompareExchange128` is unconditional). Without `-mcx16` on gcc/clang, both `__sync_*` and `__atomic_*` reject `__int128` CAS. |
| arm64 (aarch64)      | Yes           | `-march=armv8.1-a+lse -mno-outline-atomics` (gcc); default LSE on Apple Silicon, `-march=armv8.1-a+lse` on Linux ARM (clang). MSVC: no flag required (`_InterlockedCompareExchange128` emits `casp`/LL+SC as appropriate). |
| 32-bit (i386, armv7) | **No**        | Gate 1 (`sizeof(pointer) == 8`) fails at compile time                                                           |

### CI cell coverage

| Cell                                      | DWCAS coverage | Notes                                                |
| ----------------------------------------- | -------------- | ---------------------------------------------------- |
| ubuntu-24.04 + gcc + x86_64               | Yes            | Macro probe + objdump verify `cmpxchg16b`            |
| ubuntu-24.04 + clang + x86_64             | Yes            | Macro probe + objdump verify `cmpxchg16b`            |
| ubuntu-24.04-arm + gcc + arm64 (native)   | Yes            | Macro probe + objdump verify `casp` / `caspal`       |
| ubuntu-24.04-arm + clang + arm64 (native) | Yes            | Macro probe + objdump verify `casp` / `caspal`       |
| macos-15 + clang + arm64                  | Yes            | Macro probe + objdump verify `casp` / `caspal`       |
| windows-2022 + MSVC + x86_64              | Yes            | Full test suite under `--cc:vcc`; macro probe + objdump steps skipped (MSVC has no `__GCC_HAVE_SYNC_COMPARE_AND_SWAP_16` and dumpbin output differs from objdump). The vcc DWCAS path is exercised end-to-end by the test suite. |
| ubuntu-24.04 + TSAN                       | Yes            | Contention tests under thread sanitizer              |
| macOS x86_64 (Intel Mac)                  | Best-effort (not in CI) | macos-13 retired 2025-12-08; macOS coverage = arm64 only. Dispatch matches Linux x86_64 + Clang (`__atomic_compare_exchange_n` on `__int128`, `-mcx16` via `nim.cfg`, emits `cmpxchg16b`). Same instructions as the tested Linux + Clang cell. PR welcome on regressions. |

The cross-compiler macro probe is the gate that fails the build *before*
any DWCAS code runs if the toolchain doesn't actually have the
underlying capability. It is intentionally redundant with the per-op
`_Static_assert` inside the emit body — the probe runs once per CI
cell, the static asserts run at every call site.

### Regression test: libatomic-fallback detection

CI's objdump verification step is a release-blocking gate that fails the
build if any `__atomic_*_16` libatomic symbol — or `__aarch64_cas16_*`
outline-atomics symbol — appears as a call target (either `bl <symbol>`
or `b <symbol>` tail-call) in either the DWCAS objdump fixture or the
`tests/test_dwcas_roundtrip.nim` test binary.

This catches accidental reintroduction of the GCC `__atomic_*_n` libcall
footgun: at width 16, GCC's generic `__atomic_*_n` builtins silently
lower to libatomic libcalls instead of inlining the appropriate DWCAS
instruction. The codebase uses the legacy `__sync_*` builtins on GCC
paths specifically to dodge this — see the atomic128 reference and
PR #14 cycle 12 for the historical incident.

Applied to: `ubuntu-24.04` (gcc x86_64), `ubuntu-24.04-arm` (gcc
aarch64), `macos-15` (Apple Clang arm64). Skipped on `windows-2022`
(MSVC uses the `_Interlocked*` family, not libatomic).

## 7. Worked example: LCRQ-style cell

The driving use case for DWCAS in v0.10.0 is the LCRQ cell, where a
producer publishes `(index, value)` atomically and a consumer claims
the same pair atomically. The pair shape is `Pair[uint64, T]` where
`first` is the index / generation half and `second` is the payload.

```nim
import debra/atomics

type
  CellValue = ptr Node   # raw pointer payload; trivially copyable
  Cell = object
    state {.align: 16.}: Atomic[Pair[uint64, CellValue]]

# Producer: publish (idx, value) only if the cell is still empty
# (i.e. its generation half matches the expected pre-publish state).
proc publish(cell: var Cell, idx: uint64, value: CellValue): bool =
  var expected = Pair[uint64, CellValue](first: idx, second: nil)
  let desired = Pair[uint64, CellValue](first: idx or 0x1'u64, second: value)
  # The producer publish is the one place we genuinely want
  # release/relaxed semantics — wrap it to silence the upgrade warning.
  dwcasOrderRelaxedCAS:
    result = cell.state.compareExchangeStrong(
      expected, desired, moRelease, moRelaxed
    )

# Consumer: claim (idx, value) atomically by swapping in the
# "claimed" sentinel (high bit set on the generation half).
proc claim(cell: var Cell, idx: uint64): CellValue =
  var snapshot = cell.state.load(moAcquire)
  while (snapshot.first and 0x1'u64) != 0'u64 and snapshot.first == (idx or 0x1):
    var expected = snapshot
    let desired = Pair[uint64, CellValue](
      first: snapshot.first or 0x8000_0000_0000_0000'u64,
      second: snapshot.second,
    )
    if cell.state.compareExchangeWeak(expected, desired):
      return snapshot.second
    snapshot = expected   # CAS-failure overwrote expected with current value
  result = nil
```

Two things to note about this example:

- **`expected` and `desired` are distinct locals.** The `compareExchange*`
  doc-comments document this as a contract: on CAS failure, `expected`
  is overwritten in place with the current value of the cell. Aliasing
  `expected` and `desired` is defined-but-confusing on the wider 16-byte
  surface and the doc-comments call it out explicitly.
- **The consumer uses `compareExchangeWeak` inside the loop.** On
  ARMv8.0 LL/SC cores (no LSE), weak-CAS may fail spuriously (`stlxp`
  is permitted to fail without contention). The loop reloads
  `expected` from the failure path and retries. On x86_64
  (`cmpxchg16b`) and on arm64 with FEAT_LSE / LSE2 (`caspal`, e.g.
  Apple Silicon, modern server chips), weak is identical to strong —
  both lower to the same single instruction and the spurious-failure
  branch never fires. See §5 "When to use Strong vs Weak" for the
  full guidance: default to Strong unless you have measured a Weak
  win on a specific ARMv8.0 target.

For the full LCRQ algorithm see the v0.10.0+ wave specs in the
`lockfreequeues` project; the cell above is just the DWCAS substrate.

## See also

- [`docs/api.md`](../api.md) — auto-generated API reference for the
  full `debra/atomics` surface (signatures, doc-comments, source links).
- `src/debra/atomics.nim` — the module preamble at lines 1–25 is the
  canonical statement of the four (now five) invariants this module
  enforces over `std/atomics`.
- `THIRD_PARTY_LICENSES.md` — DWCAS compiler-dispatch pattern adapted
  from [atomic128](https://github.com/patternnoster/atomic128) by
  patternnoster (MIT). Pinned upstream commit
  `d45ba3d348a9620a25552f9cf50dc7ccef05ef90`.
