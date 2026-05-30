# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] - 2026-05-30

### Added

- `unregisterThread*[MaxThreads, CC]` runtime API in `src/debra.nim`.
  Releases the per-thread slot previously claimed via `registerThread`,
  making the slot available for reuse by a subsequent registration on
  the same or another thread. `{.raises: [].}`; idempotent on double
  call and stale/out-of-range `handle.idx`. Thread-affine and
  no-in-flight-pin contracts are caller obligations, documented in the
  proc's doc comment. Clear order is (1) `threads[idx].threadId`
  release-store to `InvalidThreadId`, (2) CAS-with-retry clear of the
  `activeThreadMask` bit, (3) clear thread-locals — mirrors the
  claim-side order in `registerThread`. Track B of the
  static-thread-affinity wave.
- `$` for `ThreadId` in `src/debra/thread_id.nim`. Custom stringifier
  rendering the opaque `Pthread` handle as `ThreadId(0xHEX)` (collateral
  fix: clang's auto-stringifier could not synthesise a `$` for the
  underlying struct, blocking equality-assertion diagnostics in the new
  unregister tests).

### Changed

- `setGlobalManager` in `src/debra/signal.nim` widened to be CC-generic
  (`CC: static PinScopeCardinality = ccSingle` default). Closes a
  v0.8.0 surface-widening gap exposed by `unregisterThread`'s
  `ccMulti` test coverage. Backward-compatible: the default keeps the
  existing single-cardinality call shape; `ccMulti` managers no longer
  hit a `type mismatch` when publishing to the signal handler.

### Other

- Pin bumped: `typestates >= 0.12.0` (was `>= 0.10.0`) for the implicit
  `TypestateOp` effect tag.

## [0.8.0] - 2026-05-24

### Changed (breaking)

- `withPin(handle): body` is deprecated. Replace with the `PinnedScope`
  RAII type: `var scope = pinScope(unpinned(handle))`. The new form runs
  unpin + close automatically at scope exit via `=destroy`. Removal is
  targeted for 0.9.0; the deprecated `withPin` template still compiles
  in 0.8.0 with a deprecation warning.
- Nine typestate-axis types gained a second generic parameter
  `CC: static PinScopeCardinality` (default `ccSingle`):
  `ThreadHandle`, `Pinned`, `RetireReady`, `Unpinned`, `Neutralized`,
  `Retired`, `Registered`, `DebraManager`, `PinnedScope`. The default
  preserves source-compatibility for all single-cardinality call sites;
  multi-pin patterns must opt in with explicit `[N, ccMulti]`.
- `bindClient`, `unbindClient`, `advance`, `currentEpoch`,
  `clientCount`, and `initDebraManager` are now generic over
  `CC: static PinScopeCardinality` (default `ccSingle` for the
  ergonomic 0.7.x-style call shape). Completes the "Step 8" surface
  widening flagged in `src/debra/types.nim` so callers can pass
  `DebraManager[N, ccMulti]` to these procs without Nim's default-CC
  rule triggering a `type mismatch`. The five wrappers infer `CC`
  from the manager argument; `initDebraManager` keeps the default so
  `initDebraManager[N]()` continues to return
  `DebraManager[N, ccSingle]`, and `initDebraManager[N, ccMulti]()`
  constructs the multi-cardinality variant directly.
- `EpochGuardContext` typestate gained a `Closed` terminal state plus a
  `close` proc transitioning `Unpinned → Closed`. The full guard
  lifecycle is now `Pinned → Unpinned → Closed`. The new state is
  exercised by `PinnedScope.=destroy`.

### Added

- `PinnedScope[MT, CC]` RAII type. `=destroy` automatically runs unpin
  and close on scope exit, including on early-return / exception paths.
- `pinScope(unpinned(handle))` constructor (verb-noun form, chosen to
  avoid name collision with `guard.pin`).
- `retireReady(scope.state)` retire chain, allowing `discard ready.retire(ptr, dtor)`
  inside a `PinnedScope` without leaving the pinned axis.
- `PinScopeCardinality` enum (`ccSingle`, `ccMulti`). `ccSingle` is the
  safe default and matches single-PinnedScope-per-thread-per-lifetime
  usage. `ccMulti` is an explicit opt-in for multi-pin patterns; see
  the migration guide for the foot-gun callout (pin ordering and limbo
  bag advancement become caller responsibilities).

### Internal

- 17 internal `withPin` call sites migrated to `PinnedScope` across
  `src/debra/` and the test/example tree.
- 60+ DR-T6 explicit-annotation sites widened across tests and examples
  to spell the new `CC` second parameter explicitly where the cardinality
  matters.
- Five typestate context object types (`ReclaimContext`, `AdvanceContext`,
  `ManagerContext`, `NeutralizeContext`, `SlotContext`) and their distinct
  sub-states, typestate declarations, and builder procs gained
  `CC: static PinScopeCardinality = ccSingle`, mirroring
  `EpochGuardContext` / `RetireContext` / `PinnedScopeContext`. The
  default `ccSingle` preserves the 0.7.x-style call shape; the parameter
  enables ccMulti managers built by `initDebraManager[N, ccMulti]()` to
  flow through the typestate context surface end-to-end, unblocking
  multi-consumer reclamation paths in downstream lock-free clients
  (e.g. `lockfreequeues` v5.0.0 multi-consumer pop body's `reclaimNow`
  tail). This completes the Step 8 widening on the typestate context
  layer that was missed in the manager-surface pass.
  The `AdvanceContext` widening implements (rather than reverses) the
  prior "intentionally CC-agnostic" intent: the advance ALGORITHM remains
  uniform across cardinalities (pure atomic epoch arithmetic, no
  CC-dependent branching), but the type system has to carry `CC` to accept
  a `ptr DebraManager[MT, CC]` field for both cardinalities. The earlier
  CHANGELOG entry asserting "no `CC` param on AdvanceContext" was based on
  the algorithmic argument; the field type still defaulted to ccSingle and
  rejected ccMulti managers at compile time. The ccSingle default preserves
  the "no migration needed" contract for existing 0.7.x-style call shapes.
- `typestates` dependency floor bumped to `>= 0.10.0`. 0.10.0 rewrote
  `typestates verify` Pass 2 from a substring scanner to an AST classifier,
  which correctly flags non-transition procs the old scanner silently
  skipped. (Supersedes the prior `>= 0.9.3` pin for the bracket-asymmetry
  fix exercised by `PinnedScope` / `EpochGuardContext`; 0.10.0 carries that
  fix as well.)
- 7 procs marked `{.notATransition.}` to satisfy the 0.10.0 AST verifier:
  `retire` / `retireBatch` (`src/debra/convenience.nim`),
  `retireReadyFromRetired` / `pinnedFromRetired`
  (`src/debra/typestates/retire.nim`), `manager` accessors on the `Active`
  and `Draining` states (`src/debra/typestates/slot.nim`), and `getManager`
  (`src/debra/typestates/manager.nim`). An audit corrected an earlier
  4-proc bot guess: `retireOnCAS` / `retireOnPublish` take a base context
  type rather than a declared-state type and are correctly excluded.
- Test count: 210 → 242 (per backend, across orc/arc/atomicArc/refc/cpp).

## [0.7.3] - 2026-05-08

### Fixed

- Data race on `signalHandlerInstalled` flag in `src/debra/signal.nim`.
  `installSignalHandler` runs from every thread's `registerThread`, so
  the unguarded `bool` read+write was racy under concurrent registration
  (TSAN-detected via downstream `lockfreequeues` v4.3 SPMC threaded
  test). The flag is now `Atomic[bool]`: fast-path bail-out reads with
  `moAcquire`, post-`sigaction` write stores with `moRelease`. Same
  change applied to `isSignalHandlerInstalled` and
  `forceReinstallSignalHandler`. The install itself is intentionally
  not CAS-guarded; a benign double-install is harmless because
  `sigaction` is thread-safe and re-arming the same handler is
  idempotent. Sibling of the 0.7.1 signal handler stride fix; same
  "signal handler init is implicitly multi-threaded" defect surface.

## [0.7.2] - 2026-05-07

### Changed

- Bumped minimum Nim version to 2.2.10 to dodge a Nim 2.2.6/2.2.8
  destructor-instantiation ICE (`expr(nkIdent); unknown node kind`)
  that fired when consumers wrap `DebraManager[N: static int]` in
  their own generic destructors. Resolved upstream by Nim 2.2.10. No
  source changes in debra; this release is packaging-only.

## [0.7.1] - 2026-05-06

### Fixed

- Signal handler walked `DebraManager.threads[]` with stale, hard-coded
  layout constants (`threadStateSize = 32`, `headerSize = 128`) that no
  longer matched the real `ThreadState[N]` size (64 bytes after the
  `currentBag` / `limboBagTail` / `advanceCounter` / `cacheLinePad`
  fields were added) or the cache-line-aligned header (256 bytes under
  `-d:CacheLineBytes=128`). For any registered thread index >= 1, the
  SIGUSR1 handler corrupted the previous slot's limbo-bag pointers and
  failed to flip the target thread's `pinned` / `neutralized` flags.
  `setGlobalManager` now captures the real stride and header offset
  from a typed `ptr DebraManager[N]` (under release ordering) so the
  handler reads them under acquire ordering and uses real
  `offsetOf(ThreadState, pinned)` / `offsetOf(ThreadState, neutralized)`
  for in-slot field access. A regression test in `tests/t_signal.nim`
  exercises the real signal-delivery path and asserts that thread 0's
  limbo-bag pointers stay intact when thread 1 receives the signal.
- Hardened the signal handler's publish ordering: `globalManagerPtr`
  is now an `Atomic[pointer]` with `moRelease` stores in
  `setGlobalManager` (pointer published last, after stride/header)
  and a `moAcquire` load in the handler (pointer loaded first), so a
  reader that observes the new pointer is guaranteed to see the
  matching stride/header. Tightened the static asserts in
  `signal.nim` to pin the absolute byte offsets of `pinned` (8) and
  `neutralized` (16), making the asserts a real tripwire for field
  reorders rather than a tautology. Documented `setGlobalManager`'s
  race constraint: it must not race with signal delivery; quiesce
  all registered threads before replacing the manager.

### Changed

- Strengthened the `tests/t_neutralize` "scanAndSignal signals real
  thread beyond threshold" test to actually exercise cross-slot signal
  delivery end-to-end (helper thread registered at slot 1 with its
  pthread handle wired into `mgr.threads[1].threadId`, slot 0 sentinel
  pointers asserted intact post-handler). The previous test stored
  `currentThreadId()` into slot 0 so the scanner skipped it, asserting
  only the threshold logic; that sidestep was structurally necessary
  before the stride bug fix because actually signaling slot >= 1 would
  have corrupted slot 0's pointer fields. Added
  `forceReinstallSignalHandler` to `debra/signal` so
  `tests/t_signal_handler` (which installs a placeholder no-op handler
  via direct `sigaction`) can restore the real handler before sibling
  tests run.

## [0.7.0] - 2026-05-02

### Changed

- Bump minimum `typestates` to 0.7.1. Requires the upstream match generic-context fix shipped in nim-typestates v0.7.1.
- `opaqueStates = true` and `initial:`/`terminal:` DSL blocks added to 7 of 9 typestate decls (RegistrationContext, ManagerContext, ReclaimContext, RetireContext, AdvanceContext, NeutralizeContext, SignalHandlerContext). The remaining 2 (EpochGuardContext, SlotContext) are intentional cycle-shaped graphs where no state is initial-eligible, so the lint flag is omitted.
- 5 hand-written `case .kind` dispatches replaced with the generated `match` macro for compile-time exhaustiveness (3 production sites in `convenience.nim` and `debra.nim`; 2 in runnableExamples in `guard.nim` and `reclaim.nim`).

### Added

- CI: `typestates verify -W --format=github src/` step in the lint job, with the typestates dep pinned to 0.7.1 for verifier determinism.

### Fixed

- 13 read-only typestate accessors in `src/debra/typestates/{guard,slot,advance,registration,neutralize,signal_handler,reclaim}.nim` now carry `{.notATransition.}`. typestates' verifier flagged these once `typestates verify -W` was wired into CI; the procs are pure data extraction and were never transitions.

## [0.6.0] - 2026-05-02

### Changed

- Hardened `ThreadState.cacheLinePad` size derivation against future field additions. Padding length is now derived from `sizeof(ThreadStateLive[MaxThreads])` (a sibling type that mirrors `ThreadState`'s live fields) instead of a hand-summed `56` constant, so adding or removing fields automatically resizes the pad. A drift-detection `static: assert` fails fast at compile time if the two types fall out of sync.

### Fixed

- Wired previously-orphaned test files into the nimble test runner: `tests/t_atomics`, `tests/t_atomics_dsl`, `tests/t_thread_id`, `tests/t_item_processing`, and `tests/t_lockfree_stack_typestates` were not imported by `tests/test.nim` and so were not exercised in CI. The compile-time-only negative test `tests/t_atomics_dsl_negative.nim` is now run via `nim check` from the `test` nimble task (it cannot be wired into `tests/test.nim` directly because doing so would import the DSL it asserts is not transitively reachable).
- `sendSignal(InvalidThreadId, ...)` now short-circuits with `ESRCH` instead of forwarding the zero handle into `pthread_kill`. Apple's libpthread happens to validate and return `ESRCH` for invalid handles, but glibc dereferences and may segfault. The corresponding test was previously fabricating a non-zero `pthread_t` (`999999`) and relying on the platform to gracefully reject it; that path is undefined behavior per POSIX (and *did* segfault on glibc, breaking CI). The test now exercises the `InvalidThreadId` path, which is the only invalid sentinel `sendSignal` supports.

### Added

- `Atomic[float32]` and `Atomic[float64]` support in `debra/atomics`.
  - `load`, `store`, `exchange`, and `compareExchangeStrong`/`compareExchangeWeak` accept floats through the existing generic path: the `nonAtomicType(T)` indirection routes float operations through the same-width integer atomic builtins via a bitcast, so `-0.0`, denormals, and NaN payloads round-trip bit-exactly. CAS uses bit-equality, matching `std::atomic<float>` semantics in C++ and the `AtomicU32::as_float`-style pattern in other languages: `+0.0` does NOT match `-0.0`, and two NaN values with distinct bit patterns do NOT compare equal.
  - `fetchAdd[T: SomeFloat]` implemented via a `compareExchangeWeak` CAS-loop because GCC's `__atomic_fetch_add_n` builtin family is integer-only on float operands. Unlike the pure bitwise ops above, `fetchAdd` performs an IEEE-754 float add: the returned old value is bit-exact, but the new stored value reflects FPU state (rounding mode, FTZ/DAZ flush-to-zero), does not preserve NaN payloads across the add, and produces +/-Inf on overflow.
  - The bitwise fetch ops (`fetchAnd`/`fetchOr`/`fetchXor`) and `fetchSub` are deliberately not provided for floats: bitwise ops have no meaningful float semantics, and `fetchSub` is expressible as `fetchAdd(-x)`.

## [0.5.0] - 2026-05-01

### Added

- Client refcount tracking on `DebraManager`. New procs `bindClient`, `unbindClient`, `clientCount`. The manager's destructor asserts `clientCount == 0` to catch the case where a client (e.g. a lock-free data structure) outlives its manager. Lock-free libraries built on nim-debra should bind in their constructor and unbind in their destructor.
- `compareExchange` as an unsuffixed-name alias for `compareExchangeStrong` in `debra/atomics`. Convenience for clients migrating from `std/atomics`.

### Changed

- Bump minimum `typestates` to 0.6.0.

## [0.4.0] - 2026-04-30

### Added

- `debra/atomics/backoff` module: spin-loop hint primitives for lock-free retry loops.
  - `cpuPause()` — per-CPU spin-loop hint. Emits inline `pause` (amd64/i386) or `yield` (arm64 and 32-bit arm) asm with `"memory"` clobber under GCC/Clang/objc-clang, and the matching `_mm_pause` (amd64/i386) / `__yield` (arm64) intrinsic from `<intrin.h>` under MSVC. No-op fallback on architectures or compilers without an established hint (correctness preserved). Named `cpuPause` (not `cpuRelax`) to avoid collision with `std/sysatomics.cpuRelax` (re-exported via `system` unless `-d:nimPreviewSlimSystem`). The stdlib version is a compiler-barrier-only fallback on non-x86 (no hardware `yield`/`pause` hint emitted); this implementation provides the real `yield` hint.
  - `schedYield()` — releases the current thread's CPU quantum to the OS scheduler. POSIX targets (Linux, macOS, BSDs) wrap `sched_yield(2)` under `when defined(posix)`; Windows wraps `SwitchToThread` under `when defined(windows)`. No-op fallback on other targets. Function-local `importc` keeps `<sched.h>` out of unrelated translation units.
  - Both procs are `{.inline.}` and exported. Zero overhead on the success path of CAS-retry loops (only invoked on failure edges by the caller).
  - Unblocks bounded-MPMC livelock fix in lockfreequeues (downstream PR coordinated separately).

## [0.3.1] - 2026-04-30

### Fixed

- Documentation drift after the 0.3.0 API rewrite. Five `let pinned = handle.pin()` snippets in `docs/guide/integration.md` and `docs/guide/neutralization.md` now use `unpinned(handle).pin()` (the form `pin`'s `sink Unpinned[MT]` parameter actually accepts).
- `docs/guide/retiring-objects.md` warned that `releaseDestructor[T]()` allocates a fresh closure per call and recommended caching it. Inverted: it returns a captureless `nimcall` proc with one address per `T`, reused across calls.
- `docs/guide/getting-started.md` described the `Destructor` value as a "closure"; corrected to "captureless function pointer".
- Suggested `requires "debra >= 0.1.0"` in `docs/guide/getting-started.md` and `docs/index.md` bumped to `>= 0.3.0`, since the surrounding examples assume `withPin` / `retain` / `releaseDestructor`.
- `docs/guide/epoch-advancement.md` heading "Worked example" → "Working example".
## [0.3.0] - 2026-04-27

### Added

- `debra/atomics` module: custom atomic primitives built on C11 `__atomic_*` builtins.
  - `Atomic[T]` type with `load`, `store`, `exchange`, `fetchAdd`, `fetchSub`, `fetchAnd`, `fetchOr`, `fetchXor`.
  - Strong and weak compare-and-swap (`compareExchange`, `compareExchangeWeak`).
  - `MemoryOrder` enum (Relaxed, Consume, Acquire, Release, AcqRel, SeqCst).
  - `threadFence`, `signalFence`, `AtomicFlag`, `CacheLineBytes`.
  - DSL submodule for symmetric load/store syntax.
  - Lock-free enforcement: rejects `ref T` and types that are not lock-free at the requested width.
  - `T` constraint is `supportsCopyMem(T)` plus a lock-free check, admitting POD object types (e.g., `ThreadId` wrapping `Pthread`) in addition to primitives.
- `debra/refptr` module: `retain`, `release`, and `releaseDestructor` helpers for the `Atomic[ptr T]` pattern. The returned `Destructor` is a top-level `nimcall` proc per instantiated `T`, so retire sites that build a destructor inline do not allocate a closure.
- `withPin` template in `debra/convenience` for pin/retire/unpin scopes. Named form binds the pinned handle to a caller-chosen identifier; unnamed form injects `it`. Auto-unpins on scope exit, including exception paths. Debug builds assert against nested pins on the same handle.
- `retireBatch` for batched retirement within a single pinned scope.
- `reclaimNow` standalone reclaim helper.
- `advanceEvery(handle, n)` for cadence-controlled epoch advancement.
- `pinnedFromRetired[MaxThreads]` helper in `debra/typestates/retire`. Symmetric to `retireReadyFromRetired`: lets a caller stay in the pinned epoch after a retire (e.g. interleaving reads with further retires) without unpinning and re-pinning.
- Explicit thread-local `threadLocalRegistered` flag. Disambiguates "registered at slot 0" from "unregistered" so the signal handler and the legacy `reclaimStart(addr manager)` path can detect calls from unregistered threads instead of mistaking slot 0 for the unregistered state.
- `=destroy` for `DebraManager` that drains per-thread limbo bags (calls each retired object's destructor and frees the bag). Required worker threads to have joined before the manager goes out of scope.
- `runnableExamples` blocks on the public API across `convenience`, `refptr`, and the typestate `guard` / `retire` / `reclaim` modules; pitfall and See-also sections in public-API doc comments.
- Epoch advancement guide at `docs/guide/epoch-advancement.md`.

### Changed

- **BREAKING**: `tryReclaim` and `reclaimNow` are now scoped to the calling thread's own limbo bags. Cross-thread reclamation has been removed. Stalled threads are still handled via `neutralizeStalled`. Callers that relied on one thread reclaiming another thread's retired objects must now invoke reclamation on each thread, or rely on the neutralization path for unresponsive threads.
- **BREAKING**: Removed `Managed[ref T]` and the `-d:allowSpinlockManagedRef` opt-in flag. The lock-free `Atomic[ptr T]` + `retain` / `release` / `releaseDestructor` pattern is the only supported path. Migrate by replacing `Atomic[Managed[ref T]]` with `Atomic[ptr T]` and using manual `retain` / `release` calls.
- Three lock-free examples (`lockfree_queue`, `lockfree_stack`, `lockfree_stack_typestates`) rewritten from `Atomic[Managed[ref T]]` to `Atomic[ptr T]` with `retain` / `release`, removing the spinlock fallback hazard that `Atomic[ref T]` carries on arc/orc.

### Removed

- `std/atomics` dependency from nim-debra source code. All atomic operations now go through `debra/atomics`.
- `Managed[ref T]` type, `managed()`, `inner()`, the `Managed[T]` overloads of `retire` and `retireAndReclaim`, and the `-d:allowSpinlockManagedRef` opt-in flag. See the BREAKING note above for migration.
- `unreffer[T]()` from `debra/limbo`. Use `releaseDestructor[T]()` from `debra/refptr` instead.
- `limboBagHead` field from `ThreadState`. The field was already documented as unused (reclamation walks from `limboBagTail`); `initDebraManager`, the manager typestate's `init` / `shutdown`, `=destroy`, and `retire` no longer write to it, and `tryReclaim` no longer maintains it. `ThreadState` retains its `CacheLineBytes` size via an explicit `cacheLinePad` field so the per-slot false-sharing fix from the previous round still holds.

### Fixed

- Cross-thread `tryReclaim` race: the previous implementation walked every thread's limbo bag list and mutated `currentBag`, `limboBagTail`, and per-bag `next` pointers without synchronization against the owning thread, which could corrupt the list or fault when reclamation fired concurrently with retire on another thread. Reclamation is now per-thread (see also the BREAKING note in Changed).
- `DebraManager` leaked all retired objects on scope exit. There was no destructor to drain per-thread limbo bags, so retired objects accumulated until process exit. Surfaced as ~62 KB leaked under LeakSanitizer in `lockfreequeues`'s Linux CI. Fixed by the new `=destroy` for `DebraManager`.
- Bag-list tail tracking in `retire`: when a new bag was allocated it was prepended to `currentBag` but `limboBagTail` was never updated, so the bag list lost its tail pointer after the second bag and multi-bag reclamation walked only the head. `retire` now maintains `limboBagTail` correctly.
- EBR retire-time epoch stamping. `bag.epoch` is now stamped on every `retire` call instead of only when a new bag is allocated. A bag accumulates retires until it fills `LimboBagSize`, and the global epoch can advance between retires. With the old behavior an object retired at epoch `K+2` could land in a bag still stamped at `K`, and the reclaimer's `bag.epoch < safeEpoch - 1` check could free it once `safeEpoch >= K+2` even though the EBR invariant requires `safeEpoch >= K+4` for that retire. Surfaced as an ASAN heap-use-after-free under `lockfreequeues`'s unbounded MPMC threaded stress test on Linux x86-64.
- EBR pin/reclaim subscription handshake. `pin` now publishes via `pinned.exchange(true, moSequentiallyConsistent)`, `loadEpochs` reads each thread's `pinned` flag with `moSequentiallyConsistent` and issues an SC RMW on `globalEpoch` before the scan, and `unpin` stores `false` with `moSequentiallyConsistent`. With every access to `pinned` ordered SC, the modification order on that location is constrained by the C11 SC total order, so the reclaimer is guaranteed to observe a value consistent with concurrent pin operations. RMWs are used instead of standalone SC thread fences because TSAN's vector-clock model does not implement standalone SC fences (`compiler-rt/.../tsan_interface_atomic.cpp` `OpFence::Atomic` -> `// FIXME(dvyukov): not implemented.`); SC RMWs are modelled correctly and emit the same hardware StoreLoad barrier (lock-prefixed op on x86, `ldaxr` / `stlxr` seq-cst pair on ARM). This is the encoding `crossbeam-epoch` uses for the same reason. Closes the TSAN data race between consumer pop and concurrent reclaim that surfaced in `lockfreequeues`'s unbounded MPMC threaded test on Linux ARM64.
- `examples/reclamation_background.nim` segfault under refc: refc's thread-local GC heap does not support cross-thread `GC_unref`. The example now skips with a clear diagnostic when compiled with `--mm:refc`.
- `releaseDestructorImpl` now declares `raises: []` explicitly to match the `Destructor` type signature.
- `advanceEvery(n)` validates `n >= 1` via `doAssert` (was `assert`) so the divisor check survives release-mode builds.
- `withPin` (both forms) now unpins via the original `Pinned` guard captured at template entry, not via reconstruction from the injected `it`/`name`. The reconstruction path was vulnerable to a null-pointer dereference if `it.retire` raised mid-call: the `move(pin)` inside the retire wrapper zeroes `it` before the assignment back, so the `finally` would unpin a zero-initialized context.
- `static_assert`/`_Static_assert` emit in `Atomic[T]` instantiation now constructs the message via `astToStr(T)` concatenation instead of a separate `$T` array element, eliminating reliance on the underspecified emit-array string-expression handling.
- `ThreadState` is now cache-line aligned to prevent false sharing across the per-thread slots in `DebraManager.threads`.
- `CacheLineBytes` is now an `{.intdefine.}` constant (default `64`) and `ThreadState`'s per-slot padding is computed as `array[CacheLineBytes - 56, byte]`. Apple Silicon, PowerPC, and other 128-byte-cache-line targets can now be supported without manual edits via `-d:CacheLineBytes=128`. The static assert on `sizeof(ThreadState) mod CacheLineBytes == 0` keeps the layout honest across overrides.
- `reclaimStart`'s stack-local SC subscribe-barrier atomic is now explicitly zero-initialized via `store(0, moRelaxed)` before its SC `fetchAdd`. Default zero-init of `Atomic[uint64]` is already correct in Nim, but the explicit store makes the intent obvious to readers and static analyzers.
- `withPin`'s nested-pin check uses `doAssert` (was `assert`) so the safety guard survives release builds. A nested pin would silently corrupt the EBR slot's `pinned` flag bookkeeping.
- `retire`'s SC `fetchAdd(0)` on shared `globalEpoch` replaced with a stack-local SC RMW plus an acquire load on `globalEpoch`. Equivalent StoreLoad barrier and S-ordering, no cross-thread cache contention on the global counter under concurrent retire. Mirrors the round-3 fix in `reclaimStart`.
- `enforceAtomicConstraints` alignment static assert is now gated by `-d:debraAllowNonLockFreeAtomics`, matching the lock-free check. Targets where natural alignment is insufficient for the requested atomic width (e.g., `uint64` on 32-bit i386 ABI where `alignof(uint64) == 4`) can opt in via the same flag instead of being unconditionally rejected.
- `compareExchangeStrong` and `compareExchangeWeak` gained single-order overloads that derive the failure order from the success order (drops the Release component per C11). Callers no longer have to spell out `failure=moAcquire` when passing `success=moAcquire`.
- `reclaimStart(addr manager)` now compares the calling thread's registered manager against `manager` via a new `threadLocalManager` threadvar (set by `register`) and returns `idx = -1` on mismatch. Without this guard, a thread registered with manager A that called `reclaimStart(addr managerB)` would reuse A's slot index against B's bag list and race with B's actual slot owner. The handle form `reclaimStart(handle)` is unaffected and still preferred.
- `Atomic[T]` instantiations compiled with `-d:debraAllowNonLockFreeAtomics` now emit a compile-time `{.warning.}` per the design doc's call-site visibility requirement (`docs/design/2026-04-25-custom-atomics.md` section 3.1). The previous behavior accepted the flag silently, hiding the relaxation from build output.
- `withPin` docstrings updated to reflect that the nested-pin check uses `doAssert` and fires in release builds (was incorrectly described as debug-only after the round-7 switch).
- `Atomic[T]` docstring documents the `sizeof(T) in {1, 2, 4, 8}` size limit explicitly. 16-byte atomics (`__int128`, double-quadword) are not currently provided; instantiation fails with a compile-time error from `nonAtomicType`.
- `advanceEvery`'s `n` parameter is now `static int` with a `static: assert n >= 1` compile-time check (was `int` with `doAssert`). Catches misconfiguration at compile time. All known call sites pass compile-time constants.

## [0.2.1] - 2025-12-18

### Added

- Pointer-based `retire(ptr, destructor)` API for lock-free memory reclamation
  - Enables truly lock-free code on all memory managers (arc, orc, refc)
  - Use with `ptr T` and `alloc0`/`dealloc` for lock-free data structures
- `retireAndReclaim(handle, ptr, destructor)` convenience proc
  - Combines pin, retire, unpin, and reclaim into a single call
  - Optional `eager` parameter controls immediate reclamation attempt
- `retireAndReclaim(handle, Managed[ref T])` overload for managed refs
- Lock-free guarantees documentation in README
  - Compile-time checks section
  - `isLockFree` verification examples
  - Recommended patterns for lock-free code

### Changed

- `Managed[ref T]` now emits compile-time error on arc/orc by default
  - `Atomic[ref T]` uses spinlocks on arc/orc, defeating lock-free guarantees
  - Use `-d:allowSpinlockManagedRef` to opt-in to spinlock fallback
  - Pointer-based retire API recommended for lock-free code
- Updated README Quick Start with both high-level and low-level API examples

## [0.2.0] - 2025-12-13

### Added

- `Managed[T]` wrapper type for GC-integrated memory management
  - Wraps `ref` objects and prevents GC collection via `GC_ref`
  - Automatic cleanup via `GC_unref` during DEBRA reclamation
  - Transparent field access via dot template
  - Works with `Atomic[Managed[T]]` for lock-free data structures
- `managed(obj)` proc to create managed objects from any `ref` type
- `unreffer[T]()` proc generates type-specific destructors for reclamation
- Multi-memory-manager CI testing (orc, arc, refc)

### Changed

- **BREAKING**: `retire()` now accepts `Managed[T]` instead of raw pointers
  - Old: `retire(ptr, destructor)`
  - New: `retire(managedObj)` - destructor is inferred automatically
- **BREAKING**: Removed pointer-based retire API entirely
- Updated `nimble test` task to run tests with all memory managers (orc, arc, refc)
- All examples updated to use `Managed[T]` pattern
- Documentation rewritten to use idiomatic Nim `ref` types instead of manual allocation

### Migration Guide

Replace pointer-based retire patterns:

```nim
# Old (0.1.x)
let ptr = cast[pointer](alloc0(sizeof(Node)))
let node = cast[ptr Node](ptr)
node[] = Node(value: 42)
discard ready.retire(ptr, proc(p: pointer) = dealloc(p))

# New (0.2.0)
type
  NodeObj = object
    value: int
  Node = ref NodeObj

let node = managed Node(value: 42)
discard ready.retire(node)
```

For self-referential types (linked lists, trees), use the `ref Obj` pattern:

```nim
type
  NodeObj[T] = object
    value: T
    next: Atomic[Managed[ref NodeObj[T]]]
  Node[T] = ref NodeObj[T]
```

## [0.1.2] - 2025-12-12

### Added

- State machine diagrams for all typestate documentation
  - `guard.svg` - EpochGuard pin/unpin lifecycle
  - `retire.svg` - Object retirement flow
  - `reclaim.svg` - Reclamation process
  - `registration.svg` - Thread registration
  - `neutralize.svg` - Neutralization protocol
  - `advance.svg` - Epoch advancement
  - `slot.svg` - Thread slot management
  - `manager.svg` - Manager initialization
  - `signal_handler.svg` - Signal handler states
- Example typestate diagrams in integration guide
  - `item_processing.svg` - Item processing pipeline
  - `lockfree_stack.svg` - Lock-free stack states

## [0.1.1] - 2025-12-12

### Added

- Typestate composition examples demonstrating integration with custom typestates
  - `item_processing.nim`: Generic item lifecycle typestate (Unprocessed → Processing → Completed|Failed)
  - `lockfree_stack_typestates.nim`: Lock-free stack with Empty/NonEmpty states using DEBRA internally
- Comprehensive test coverage for typestate composition
  - `t_item_processing.nim`: 8 tests for item processing transitions
  - `t_lockfree_stack_typestates.nim`: 10 tests for lock-free stack operations
- Typestate Composition section in integration guide
- `testExamples` nimble task to compile and run all example files
- Status badges in README

### Changed

- `pop()` in lock-free stack now returns `Option[Unprocessed[T]]` instead of bare type
  - Properly handles race condition where another thread pops the last item
  - Eliminates need for potentially invalid `default(T)` placeholder
- Improved sink parameter usage in slot transitions for proper move semantics
- Enhanced documentation for neutralization handling and thread registration

### Fixed

- Example files now wrapped in procs to fix `=dup` lifetime issues with Nim's `when isMainModule`
- Removed `nim.cfg` from repo (was causing CI failures due to Atlas local paths)

## [0.1.0] - 2025-12-10

### Added
- Initial implementation of DEBRA+ algorithm
- Typestate-enforced API for correct operation sequencing
- DebraManager for coordinating epoch-based reclamation across threads
- Thread registration with ThreadHandle
- Pin/unpin operations with EpochGuard typestate
- Object retirement with limbo bags
- Reclamation of objects from safe epochs
- Signal-based neutralization for stalled threads
- ThreadSlot typestate for slot lifecycle management
- EpochAdvance typestate for epoch advancement
- ThreadId wrapper for cross-platform signal delivery
- Documentation site with MkDocs Material theme
- CI workflow for running tests on Linux
- Docs deployment workflow for GitHub Pages
- Integration tests

[Unreleased]: https://github.com/elijahr/nim-debra/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/elijahr/nim-debra/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/elijahr/nim-debra/compare/v0.7.3...v0.8.0
[0.7.3]: https://github.com/elijahr/nim-debra/compare/v0.7.2...v0.7.3
[0.7.2]: https://github.com/elijahr/nim-debra/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/elijahr/nim-debra/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/elijahr/nim-debra/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/elijahr/nim-debra/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/elijahr/nim-debra/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/elijahr/nim-debra/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/elijahr/nim-debra/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/elijahr/nim-debra/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/elijahr/nim-debra/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/elijahr/nim-debra/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/elijahr/nim-debra/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/elijahr/nim-debra/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/elijahr/nim-debra/releases/tag/v0.1.0
