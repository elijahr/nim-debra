# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- `reclaimStart`'s stack-local SC subscribe-barrier atomic is now explicitly zero-initialized via `store(0, moRelaxed)` before its SC `fetchAdd`. Default zero-init of `Atomic[uint64]` is already correct in Nim, but the explicit store makes the intent obvious to readers and static analyzers.
- `withPin`'s nested-pin check uses `doAssert` (was `assert`) so the safety guard survives release builds. A nested pin would silently corrupt the EBR slot's `pinned` flag bookkeeping.
- `retire`'s SC `fetchAdd(0)` on shared `globalEpoch` replaced with a stack-local SC RMW plus an acquire load on `globalEpoch`. Equivalent StoreLoad barrier and S-ordering, no cross-thread cache contention on the global counter under concurrent retire. Mirrors the round-3 fix in `reclaimStart`.
- `enforceAtomicConstraints` alignment static assert is now gated by `-d:debraAllowNonLockFreeAtomics`, matching the lock-free check. Targets where natural alignment is insufficient for the requested atomic width (e.g., `uint64` on 32-bit i386 ABI where `alignof(uint64) == 4`) can opt in via the same flag instead of being unconditionally rejected.
- `compareExchangeStrong` and `compareExchangeWeak` gained single-order overloads that derive the failure order from the success order (drops the Release component per C11). Callers no longer have to spell out `failure=moAcquire` when passing `success=moAcquire`.

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

[Unreleased]: https://github.com/elijahr/nim-debra/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/elijahr/nim-debra/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/elijahr/nim-debra/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/elijahr/nim-debra/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/elijahr/nim-debra/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/elijahr/nim-debra/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/elijahr/nim-debra/releases/tag/v0.1.0
