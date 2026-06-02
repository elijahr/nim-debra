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
| MSVC                                 | Supported                                                           | **Not supported** (gcc / clang / llvm_gcc / nintendoswitch only)                 |
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
- **You're on MSVC, or any compiler that isn't gcc / clang / llvm_gcc /
  nintendoswitch.** `debra/atomics` errors out at import time on
  unsupported toolchains. v0.10.x does not target MSVC.
- **You're on a 32-bit ABI and want 16-byte atomics.** DWCAS requires a
  64-bit target. The 32-bit ABI fails gate 1 (`sizeof(pointer) == 8`)
  at compile time.
- **You want fetch-and-add on a 16-byte cell.** `fetchAdd` / `fetchSub`
  / `fetchAnd` / `fetchOr` / `fetchXor` are scoped to `SomeInteger` and
  `SomeFloat` ≤ 8 bytes. 16-byte arithmetic RMW is out of scope for
  v0.10.0; LCRQ doesn't need it.
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
| `compareExchange*` (failure)           | Must be a load-class order, must not be stronger than success           |
| Any DWCAS op (16-byte) at the instruction level | Always `moSequentiallyConsistent` regardless of what you pass |

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
  pairs are emitted on either path.
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

| Compiler       | Supported     | Notes                                              |
| -------------- | ------------- | -------------------------------------------------- |
| gcc            | Yes           | Requires `-mcx16` on x86_64 (shipped via nim.cfg)  |
| clang          | Yes           | x86_64 emit uses `__atomic_*`; arm64 uses LSE      |
| llvm_gcc       | Yes           | Treated as gcc-shape                               |
| nintendoswitch | Accepted      | (GCC __atomic family present)                      |
| MSVC           | **No**        | Build fails at module import                       |

### Supported architectures (for DWCAS)

| Arch                 | Supported     | Required compiler flag                                              |
| -------------------- | ------------- | ------------------------------------------------------------------- |
| x86_64 (amd64)       | Yes           | `-mcx16` (gcc); none needed for clang (uses `__atomic_*` directly)  |
| arm64 (aarch64)      | Yes           | `-march=armv8.1-a+lse -mno-outline-atomics` (gcc); LSE required     |
| 32-bit (i386, armv7) | **No**        | Gate 1 (`sizeof(pointer) == 8`) fails at compile time               |

### CI cell coverage

| Cell                                      | DWCAS coverage | Notes                                                |
| ----------------------------------------- | -------------- | ---------------------------------------------------- |
| ubuntu-24.04 + gcc + x86_64               | Yes            | Macro probe + objdump verify `cmpxchg16b`            |
| ubuntu-24.04 + clang + x86_64             | Yes            | Macro probe + objdump verify `cmpxchg16b`            |
| ubuntu-24.04 + gcc + arm64 (cross / QEMU) | Yes            | Macro probe + objdump verify `casp` / `caspal`       |
| macos-15 + clang + arm64                  | Yes            | Macro probe + objdump verify `casp` / `caspal`       |
| ubuntu-24.04 + TSAN                       | Yes            | Contention tests under thread sanitizer              |
| macOS x86_64                              | **Not in CI**  | macos-13 retired 2025-12-08; macOS coverage = arm64 only |

The cross-compiler macro probe is the gate that fails the build *before*
any DWCAS code runs if the toolchain doesn't actually have the
underlying capability. It is intentionally redundant with the per-op
`_Static_assert` inside the emit body — the probe runs once per CI
cell, the static asserts run at every call site.

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
