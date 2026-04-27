# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-04-25

### Added

- `debra/atomics` module: custom atomic primitives built on C11 `__atomic_*` builtins
  - `Atomic[T]` type with `load`, `store`, `exchange`, `fetchAdd`, `fetchSub`, `fetchAnd`, `fetchOr`, `fetchXor`
  - Strong and weak compare-and-swap (`compareExchange`, `compareExchangeWeak`)
  - `MemoryOrder` enum (Relaxed, Consume, Acquire, Release, AcqRel, SeqCst)
  - `threadFence`, `signalFence`, `AtomicFlag`, `CacheLineBytes`
  - DSL submodule for symmetric load/store syntax
  - Lock-free enforcement: rejects `ref T` and types that are not lock-free at the requested width
  - `T` constraint is `supportsCopyMem(T)` plus a lock-free check, admitting POD object types (e.g., `ThreadId` wrapping `Pthread`) in addition to primitives
- `debra/refptr` module: `retain`, `release`, and `releaseDestructor` helpers for `Atomic[ptr T]` patterns
- `withPin` template in `debra/convenience` for ergonomic pin/retire/unpin scopes
  - Named form binds the pinned handle to a user-chosen identifier
  - Unnamed form injects `it` into the body
  - Auto-unpin on scope exit, including exception paths
  - Debug assertion against nested pins
- `retireBatch` for batched retirement within a single pinned scope
- `reclaimNow` standalone reclaim helper
- `advanceEvery(handle, n)` for cadence-controlled epoch advancement
- `runnableExamples` blocks on the public API across `convenience`, `refptr`, `managed`, and the typestate `guard` / `retire` / `reclaim` modules
- Pitfall and See-also sections in public-API doc comments
- Epoch advancement guide at `docs/guide/epoch-advancement.md`
- `pinnedFromRetired[MaxThreads]` helper in `debra/typestates/retire`. Symmetric to `retireReadyFromRetired`: lets a caller stay in the pinned epoch after a retire (e.g. interleaving reads with further retires) without unpinning and re-pinning.

### Changed

- **BREAKING**: `tryReclaim` and `reclaimNow` are now scoped to the calling thread's own limbo bags. Cross-thread reclamation has been removed. Stalled threads are still handled via `neutralizeStalled`. Callers that relied on one thread reclaiming another thread's retired objects must now invoke reclamation on each thread, or rely on the neutralization path for unresponsive threads.
- Three lock-free examples (`lockfree_queue`, `lockfree_stack`, `lockfree_stack_typestates`) rewritten from `Atomic[Managed[ref T]]` to `Atomic[ptr T]` with `retain` / `release`, removing the spinlock fallback hazard that `Atomic[ref T]` carries on arc/orc.
- **BREAKING**: Removed `Managed[ref T]` and the `allowSpinlockManagedRef` opt-in flag. The lock-free `Atomic[ptr T]` + `retain`/`release`/`releaseDestructor` pattern is the only supported path. Migrate by replacing `Atomic[Managed[ref T]]` with `Atomic[ptr T]` and using manual `retain`/`release` calls.

### Removed

- `std/atomics` dependency from nim-debra source code. All atomic operations now go through `debra/atomics`.
- `Managed[ref T]` type, `managed()`, `inner()`, `Managed[T]` overloads of `retire` and `retireAndReclaim`, and the `-d:allowSpinlockManagedRef` opt-in flag. See the breaking-change note above for migration.
- `unreffer[T]()` from `debra/limbo`: was a duplicate of `releaseDestructor[T]()` from `debra/refptr` retained during the `Managed[T]` removal to avoid touching tests. Use `releaseDestructor[T]()` instead.

### Fixed

- Reclaim race in `tryReclaim`: the previous implementation walked other threads' limbo bag lists without synchronization, which could fault when reclamation actually fired concurrently with retire. Reclamation is now per-thread.
- Missing publication fence in `pin()`. The `pinned=true` store used `moRelease`, but the caller's subsequent loads of the data the pin is meant to protect could be reordered before that store became globally visible (StoreLoad reordering, observable on x86 between distinct addresses and worse on weakly-ordered targets). A reclaimer scanning per-thread `pinned` flags could observe `pinned=false` after the pinning thread had already loaded a pointer it was about to dereference, and free the object out from under it. `pin()` now issues `threadFence(moSequentiallyConsistent)` after the `pinned=true` store. This is the standard EBR publication barrier (matches Crossbeam's pin path). TSAN under `lockfreequeues`'s unbounded queue stress tests was flagging this; the fence clears the warning.
- Missing subscription fence in `loadEpochs` (the reclaim path). Standard EBR requires SC fences on BOTH sides — a publication fence on `pin` (above) AND a subscription fence on the reclaimer before it reads other threads' `pinned` flags. With only the publication side, a reclaimer's acquire-load of another thread's `pinned` could miss a concurrent `pinned=true` store, causing the reclaimer to compute a too-permissive `safeEpoch` and free objects the still-pinning thread is reading. `loadEpochs` now issues `threadFence(moSequentiallyConsistent)` before iterating the per-thread state. Surfaced as a TSAN data race between `pop` reading segment data and a concurrent `tryReclaim` freeing the segment in `lockfreequeues`'s unbounded MPMC threaded test on Linux x86-64.
- Bag-list tail tracking in `retire`: new bags were prepended but `limboBagTail` was never updated, so multi-bag reclamation was effectively a no-op. `retire` now correctly appends and maintains the tail pointer.
- Retire-time `bag.epoch` now records the current global epoch (paired with `pin`'s and `loadEpochs`'s SC sync points), not the pin's captured epoch. Using the pin's captured epoch could leave `bag.epoch` smaller than a still-pinning reader's epoch, so `bag.epoch < safeEpoch - 1` could pass while the reader was still actively dereferencing the retired pointer — a use-after-free. Surfaced as an ASAN heap-use-after-free in `lockfreequeues`'s unbounded MPMC threaded test on Linux x86-64.
- EBR publication/subscription/retire SC sync points re-encoded from `threadFence(moSequentiallyConsistent)` to SC read-modify-write operations: `pin()` now uses `pinned.exchange(true, moSequentiallyConsistent)`, and `loadEpochs`/`retire` use `globalEpoch.fetchAdd(0, moSequentiallyConsistent)`. The previous fence-based encoding is C11-equivalent but standalone SC thread fences are not modelled by TSAN's vector clocks (per `compiler-rt/lib/tsan/rtl/tsan_interface_atomic.cpp`, `OpFence::Atomic` -> `// FIXME(dvyukov): not implemented.`), so TSAN on Linux ARM64 reported phantom data races between consumer pop and concurrent reclaim even though the protocol is sound. SC RMWs are modelled correctly and emit the same hardware StoreLoad barrier (`lock`-prefixed instruction on x86, `ldaxr`/`stlxr` seq-cst pair on ARM). Crossbeam's `crossbeam-epoch` uses the same encoding for the same reason.
- `loadEpochs` now reads each thread's `pinned` flag with `moSequentiallyConsistent` (was `moAcquire`), and `unpin` stores `false` with `moSequentiallyConsistent` (was `moRelease`). With every access to `pinned` SC, the modification order on that location is fully ordered by the C11 SC total order S, so the reclaimer is guaranteed to observe a value consistent with concurrent pin RMWs. The previous Acquire load on a different SC location (`globalEpoch`) did not constrain the modification order on `pinned` itself, leaving a window where the reclaimer could observe `pinned=false` for a thread that had already published `pinned=true` — exactly the EBR subscription gap that crossbeam closes by packing pin+epoch into a single SC-accessed word.
- `bag.epoch` is now stamped on every `retire` call, not just at bag allocation. A bag accumulates retires until it fills `LimboBagSize`, and the global epoch can advance between retires. With the old behavior an object retired at epoch K+2 would land in a bag still stamped at K, and the reclaimer's `bag.epoch < safeEpoch - 1` check would free it once `safeEpoch >= K+2` even though the EBR invariant requires `safeEpoch >= K+4` for that retire to be safe. This was the underlying cause of TSAN data races (and real use-after-free under concurrent retire/reclaim) reported in `lockfreequeues`'s unbounded MPMC threaded test on Linux x86-64. Bumping `bag.epoch = epoch` on each retire is over-conservative for earlier objects in the bag (they live longer than necessary) but restores the safety invariant for later objects.
- `examples/reclamation_background.nim` segfault under refc: refc's thread-local GC heap does not support cross-thread `GC_unref`. The example now skips with a clear diagnostic when compiled with `--mm:refc`.
- `releaseDestructor[T]()` no longer allocates a fresh closure on each call. The returned `Destructor` is now a plain `nimcall` proc address (one per `T` instantiation) with no captured environment, so retire sites that build the destructor inline pay no per-call allocation.

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
