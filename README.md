# nim-debra

[![CI](https://github.com/elijahr/nim-debra/actions/workflows/ci.yml/badge.svg)](https://github.com/elijahr/nim-debra/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Nim Version](https://img.shields.io/badge/nim-%E2%89%A5%202.2.0-orange.svg)](https://nim-lang.org/)
[![Documentation](https://img.shields.io/badge/docs-latest-green.svg)](https://elijahr.github.io/nim-debra/latest/)

DEBRA+ epoch-based memory reclamation for lock-free data structures in Nim.
Reads pin a global epoch counter, retired pointers wait until every active
thread has moved past that epoch, and reclamation never blocks or pauses.

**Status:** beta. The API is shipped and exercised by
[lockfreequeues](https://github.com/elijahr/lockfreequeues), but parts of it
(notably `advanceEvery` and `neutralizeStalled`) may still change before 1.0.

## Why epoch-based reclamation

The hard problem in any lock-free data structure is deciding when it is safe
to free a node you have just unlinked, since another thread may still be
reading it. GC solves this with stop-the-world pauses, and atomic refcounting
solves it with an RMW on every dereference. Both are expensive on the read
path.

DEBRA+ trades a small amount of memory headroom for a read path that costs
roughly two sequentially-consistent atomic stores per critical section,
regardless of how much you read inside it. Threads pin the global epoch on
entry, retired pointers are tagged with the epoch they were retired in, and
reclamation only frees a pointer once every registered thread has observed
an epoch later than that.

This implementation follows Brown 2017, including the SIGUSR1 protocol for
neutralizing threads that have stalled inside a critical section. It ships
its own atomics module (separate from `std/atomics`) that only compiles
operations the hardware does lock-free, so accidentally lock-ful
"lock-free" code becomes a build error rather than a silent regression.

## Installation

```sh
nimble install debra
```

Requires Nim 2.2.0 or newer and a GCC, Clang, LLVM-GCC, or Nintendo Switch
toolchain. The atomics module wraps the `__atomic_*` builtins and does not
support MSVC.

## Quick start

A complete pin / retire / reclaim cycle on a single thread:

```nim
import debra

type
  NodeObj = object
    value: int
  Node = ref NodeObj

var manager = initDebraManager[4]()
setGlobalManager(addr manager)
let handle = registerThread(manager)

handle.withPin:
  let node = retain Node(value: 42)
  it.retire(cast[pointer](node), releaseDestructor[NodeObj]())

discard reclaimNow(handle)
```

`withPin` enters the critical section, exposes a `RetireReady` value bound
to the name `it`, and unpins on exit even if the body raises. Outside the
block, the typestate machinery refuses to compile a `retire` because there
is no pinned epoch to attach it to.

`retain` increments the GC refcount and returns a raw `ptr`, which is what
the atomic slots in your data structure should hold. The matching
`releaseDestructor[T]()` returns a per-type function pointer that runs at
reclamation time and balances the retain.

`reclaimNow` performs one best-effort sweep over the calling thread's
retired list. Returning zero is normal at startup — no epoch is yet old
enough to be safe. In production, drive reclamation periodically with
`advanceEvery` and `reclaimNow`, or attach `retireAndReclaim` to ad-hoc
retire sites.

## Usage

### Build a lock-free stack

The full Treiber stack at
[`examples/lockfree_stack.nim`](examples/lockfree_stack.nim) shows the
production-shaped pattern: an atomic `head: Atomic[ptr NodeObj[T]]`, `push`
racing on a CAS, and `pop` retiring the displaced node inside its `withPin`
block.

```nim
proc push*[T](stack: var Stack[T], value: T) =
  let newNode = retain Node[T](value: value)
  stack.handle.withPin:
    while true:
      let oldHead = stack.head.load(moAcquire)
      newNode.next.store(oldHead, moRelaxed)
      var observed = oldHead
      if stack.head.compareExchangeStrong(
          observed, newNode, moRelease, moRelaxed):
        break
```

### Bridge a `ref` into an atomic slot

`Atomic[ref T]` does not compile — our atomics module rejects it at the
type level, with an error that points you at the bridge below. (Nim's
`std/atomics` would give you a spinlock-backed implementation here, which
is why nim-debra ships its own atomics module instead of using it.) Use
`Atomic[ptr T]` and the retain/release helpers:

```nim
var slot: Atomic[ptr NodeObj]
slot.store(retain Node(value: 7), moRelease)

handle.withPin:
  let old = slot.exchange(retain Node(value: 8), moAcquireRelease)
  if old != nil:
    it.retire(cast[pointer](old), releaseDestructor[NodeObj]())
```

Each `retain` must be balanced by exactly one `release`.
`releaseDestructor[T]()` is a captureless function pointer, so handing it
to `retire` does not allocate.

### Release a registration slot

`registerThread` claims one slot in the manager's per-thread table; the
fixed-size table is bounded by the `MaxThreads` static parameter. If a
worker thread exits while its slot stays claimed, that capacity is lost
for the lifetime of the manager. `unregisterThread` releases the slot
for reuse:

```nim
proc unregisterThread*[
    MaxThreads: static int, CC: static PinScopeCardinality = ccSingle
](
    manager: var DebraManager[MaxThreads, CC],
    handle: ThreadHandle[MaxThreads, CC],
) {.raises: [].}
```

The `CC` parameter binds via the `manager` argument, so the default
`DebraManager[N]` (which carries `CC = ccSingle`) keeps the same call
shape; `DebraManager[N, ccMulti]` is also accepted. See
[`examples/unregister_thread.nim`](examples/unregister_thread.nim) for a
runnable register → work → unregister cycle that demonstrates slot reuse.

**Caller obligations** (partially enforced at runtime via a defensive
`doAssert` — see `src/debra.nim:80-129` for the full contract):

- **Idempotent.** A second call with the same `handle` is a no-op. The
  routine bounds-checks `handle.idx` and short-circuits if the slot's
  mask bit is already clear, so double-unregister is safe.
- **Thread-affine.** Must be called from the same OS thread that called
  `registerThread` to obtain `handle`. The per-thread bookkeeping
  (`threadLocalIdx`, `threadLocalRegistered`, `threadLocalManager`) is
  cleared at the end of the call; a cross-thread call leaves the owning
  thread's threadvars stale and will misroute future signal delivery.
- **No in-flight pin.** Any `PinnedScope` opened against `handle` must
  have been closed before this call. `unregisterThread` does not un-pin;
  releasing a slot with an active pin is a use-after-free.
- **Stale-handle aliasing is undetected.** `ThreadHandle` carries no
  epoch/generation. If a slot has already been released and reclaimed by
  another thread, passing the original handle here may corrupt the new
  owner's slot. Do not retain handles past the matching
  `unregisterThread`.

### Recover from a stalled thread

If a registered thread has been parked inside a system call for too long,
the reclaimer can be blocked indefinitely waiting for it to leave its
epoch. `neutralizeStalled` sends SIGUSR1 to the offender so the signal
handler can unpin it artificially:

```nim
let signalled = neutralizeStalled(manager, epochsBeforeNeutralize = 4)
if signalled > 0:
  echo "Neutralized ", signalled, " stalled threads"
```

This requires that `setGlobalManager` has been called and that the
application has not claimed SIGUSR1 for something else.

## Features

- **Epoch-based reclamation.** Two SC atomic stores per critical section on the read path; no per-access RMWs.
- **Custom atomics module.** Compile-time error for any atomic that is not `__atomic_always_lock_free` at the requested width, and `Atomic[ref T]` is rejected outright.
- **Typestate-checked API.** Pin → retire → unpin transitions are enforced at compile time. Calling `retire` outside a pinned scope is a type error, not a runtime crash.
- **Signal-based neutralization.** The SIGUSR1 protocol from Brown 2017 unblocks reclamation when registered threads are stalled inside the kernel.
- **Memory-manager coverage.** CI runs the test suite under `--mm:arc`, `--mm:orc`, `--mm:atomicArc`, and `--mm:refc`, plus the C++ backend.
- **Convenience layer.** `withPin`, `retireAndReclaim`, and `advanceEvery` cover the common cases without dropping down to typestate primitives.

## Memory managers

`arc`, `orc`, and `atomicArc` all use a shared atomic refcount, so a
`retain` on thread A may be balanced by a `release` on thread B. That is
what most lock-free designs want.

`refc` is different: its GC heap is thread-local, so `release` must run on
the same thread as the `retain` that pairs with it. If your design hands
retired pointers off to a background reclaim thread, the pattern is fine
on the other three managers but is undefined behaviour under refc.

The full per-manager notes, plus the TSAN and ASAN test recipes, live in
[`docs/safety-model.md`](docs/safety-model.md).

## Documentation

- [Documentation site](https://elijahr.github.io/nim-debra/latest/) — guides, API reference, and design notes.
- [Getting started](https://elijahr.github.io/nim-debra/latest/guide/getting-started/) and [Concepts](https://elijahr.github.io/nim-debra/latest/guide/concepts/) are the most useful first reads.
- [Integration guide](https://elijahr.github.io/nim-debra/latest/guide/integration/) for wiring DEBRA into an existing data structure.
- [`docs/design/2026-04-25-custom-atomics.md`](docs/design/2026-04-25-custom-atomics.md) — design rationale for the custom atomics module.

## Used by

- [lockfreequeues](https://github.com/elijahr/lockfreequeues) — SPSC, MPMC, bounded, and unbounded lock-free queues backed by nim-debra.

If you ship a project that depends on nim-debra, send a PR adding it here.

## References

- Trevor Brown. [Reclaiming Memory for Lock-Free Data Structures: There Has to Be a Better Way](https://arxiv.org/abs/1712.01044). 2017. The DEBRA+ algorithm with signal-based neutralization for stalled threads.
- Keir Fraser. [Practical Lock-Freedom](https://www.cl.cam.ac.uk/techreports/UCAM-CL-TR-579.pdf). University of Cambridge Technical Report UCAM-CL-TR-579, 2004. The original epoch-based reclamation work that DEBRA+ builds on.
- [nim-typestates](https://github.com/elijahr/nim-typestates) — the compile-time typestate library used to enforce the DEBRA+ protocol.

## Contributing

Bug reports and PRs are welcome. Development setup, the cross-manager test
matrix, and PR conventions are in [docs/contributing.md](docs/contributing.md).

## Attribution

nim-debra v0.10.0's 16-byte atomics (DWCAS) implementation borrows the
compiler-dispatch pattern from [atomic128](https://github.com/patternnoster/atomic128)
by patternnoster (MIT licensed). The GCC `__sync_val_compare_and_swap` /
Clang `__atomic_compare_exchange_n` split documented in
atomic128's `atomic128_ref.hpp` is the canonical reference for working
around GCC's silent libatomic-fallback behavior on `__atomic_compare_exchange_16`.
See [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) for the verbatim MIT
license text, pinned to commit `d45ba3d348a9620a25552f9cf50dc7ccef05ef90`.

## License

MIT. See the `license` field in [`debra.nimble`](debra.nimble).
