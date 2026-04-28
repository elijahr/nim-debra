# nim-debra

[![CI](https://github.com/elijahr/nim-debra/actions/workflows/ci.yml/badge.svg)](https://github.com/elijahr/nim-debra/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Nim Version](https://img.shields.io/badge/nim-%E2%89%A5%202.2.0-orange.svg)](https://nim-lang.org/)
[![Documentation](https://img.shields.io/badge/docs-latest-green.svg)](https://elijahr.github.io/nim-debra/latest/)

DEBRA+ safe memory reclamation for lock-free data structures in Nim.

**Status:** Beta — used by [lockfreequeues](https://github.com/elijahr/lockfreequeues)
in production-grade tests; API may still change before 1.0.

> **Upgrading from 0.2.x?** `Managed[ref T]` has been removed. Replace
> `Atomic[Managed[ref T]]` slots with `Atomic[ptr T]` and use the
> `retain` / `releaseDestructor` bridge described below. See
> [CHANGELOG.md](CHANGELOG.md) for the full migration path.

## The problem this solves

If thread A is reading a pointer at the same instant thread B frees the
object behind it, thread A is reading freed memory. In a lock-free data
structure that is the central correctness problem: removed nodes have to
stay alive until every thread that *might* still be reading them has moved
on. Garbage collection solves this with overhead and pauses; reference
counting solves it with atomic increments on every read.

DEBRA+ solves it with epochs. Threads pin a global epoch counter while they
work, retired objects are tagged with the epoch they were retired in, and
reclamation only frees an object once every active thread has moved past
that epoch. There are no pauses, the read path is roughly the cost of two
sequentially-consistent atomic stores, and the bookkeeping never blocks.

This library implements DEBRA+ (Brown 2017) plus its signal-based
neutralization protocol for stalled threads, on top of a custom atomics
module that refuses to compile anything that would silently fall back to a
spinlock.

## Installation

```sh
nimble install debra
```

Requires Nim 2.2.0 or newer and a GCC, Clang, LLVM-GCC, or Nintendo Switch
toolchain. The atomics module wraps `__atomic_*` builtins; MSVC is not
supported. See [`src/debra/atomics.nim`](src/debra/atomics.nim) for the
exact backend gate.

## Quick start

The example below is a stand-in for a real lock-free push: it builds a
single-linked list head that any thread can swap, retires the displaced
node so concurrent readers don't see a dangling pointer, and reclaims once
the epoch is safe. The `enqueue` body of
[`examples/lockfree_queue.nim`](examples/lockfree_queue.nim) is the
production-shaped version of the same pattern.

```nim
import debra
import debra/atomics

type
  NodeObj = object
    value: int
    next: Atomic[ptr NodeObj]
  Node = ref NodeObj

# One manager per process. `64` is the maximum number of registered threads.
var manager = initDebraManager[64]()
setGlobalManager(addr manager)

# Each thread that touches the data structure registers once.
let handle = registerThread(manager)

var head: Atomic[ptr NodeObj]

proc push(value: int) =
  # `retain` increments the GC ref count and returns a raw `ptr NodeObj`
  # safe for atomic storage. The matching `release` runs from the
  # destructor we hand to `retire` below.
  let newNode = retain Node(value: value)

  handle.withPin:
    while true:
      let oldHead = head.load(moAcquire)
      newNode.next.store(oldHead, moRelaxed)
      var expected = oldHead
      if head.compareExchangeStrong(expected, newNode, moRelease, moRelaxed):
        if oldHead != nil:
          it.retire(cast[pointer](oldHead), releaseDestructor[NodeObj]())
        break

push(1); push(2); push(3)

# In real code, run reclamation periodically (e.g. via `advanceEvery` plus
# `reclaimNow`) to free retired nodes once every thread has moved past
# their epoch.
discard reclaimNow(handle)
```

`withPin` enters the critical section, injects a `RetireReady` handle named
`it`, and unpins on exit even if the body raises. Inside the block you can
call `it.retire(p, dtor)` any number of times; outside it, the typestate
machinery will refuse to compile a retire because there is no pinned epoch
to attach it to.

## Allocating retired objects

The `retain` / `releaseDestructor` pair is the bridge that lets a Nim `ref`
live inside an `Atomic[ptr T]` slot without the silent spinlock fallback
that `Atomic[ref T]` would use under arc/orc. In isolation it looks like
this:

```nim
type
  NodeObj = object
    value: int
  Node = ref NodeObj

var slot: Atomic[ptr NodeObj]

# Store: pin the GC, install pointer atomically.
slot.store(retain Node(value: 7), moRelease)

# Replace and retire the displaced value.
handle.withPin:
  let old = slot.exchange(retain Node(value: 8), moAcquireRelease)
  if old != nil:
    it.retire(cast[pointer](old), releaseDestructor[NodeObj]())
```

Each `retain` must be balanced by exactly one `release`. The destructor
returned by `releaseDestructor[T]()` is a per-`T` function pointer with no
captured environment, so handing it to `retire` does not allocate.

## API surface

You will mostly use the convenience layer; the typestate primitives are
there for fine-grained control or unusual lifecycles.

- `initDebraManager[MaxThreads]()` — allocate one manager per process,
  templated on the maximum number of threads that can register.
- `setGlobalManager(addr manager)` — required for the SIGUSR1 neutralization
  path; `registerThread` installs the signal handler the first time it runs.
- `registerThread(manager)` — call once per thread, returns a `ThreadHandle`
  that ties subsequent operations to that thread's slot.
- `withPin(handle)` — pin / unpin scope; injects `it: var RetireReady` for
  retires inside the body. Auto-unpins even on exception. Nested pinning on
  the same handle is rejected (debug assert).
- `it.retire(p, dtor)` — inside `withPin`, mark `p` for deferred destruction.
  `it.retireBatch(items)` retires several `(pointer, Destructor)` pairs in
  one go and skips the per-object pin/unpin cycle.
- `reclaimNow(handle)` — best-effort reclamation pass for the calling
  thread's own retired objects. Returns 0 when no epoch is safe yet; that is
  normal at startup, not an error.
- `retireAndReclaim(handle, p, dtor)` — pin, retire, unpin, and try to
  reclaim in one call. Use it for ad-hoc retires; prefer `withPin` +
  `retireBatch` for hot paths.
- `advanceEvery(handle, n)` — cadence-controlled epoch advancement. Most
  calls are a non-atomic increment; only every Nth call performs the atomic
  store on the global epoch. `n = 32`–`128` is a reasonable starting point
  for queue hot paths.
- `neutralizeStalled(manager)` — send SIGUSR1 to threads that haven't moved
  through an epoch in too long, so reclamation can make progress without
  them. Used by long-running services where a registered thread could block
  on something the reclaimer doesn't control.
- `retain(obj)` / `release(p)` / `releaseDestructor[T]()` — the GC-bridge
  helpers from `debra/refptr`.

`advanceEvery` and `neutralizeStalled` are newer than the rest of the API;
their signatures could still change before 1.0.

The full reference lives at
[elijahr.github.io/nim-debra](https://elijahr.github.io/nim-debra/latest/),
including the typestate transitions (`unpinned`, `pin`, `retireReady`,
`reclaimStart`, etc.) you'd reach for when composing custom workflows.

## Memory managers and the safety model

`Atomic[ref T]` fails to compile under any memory manager, and `Atomic[T]`
fails to compile for any `T` that is not `__atomic_always_lock_free` at the
requested width. The error message points you at the
`Atomic[ptr T]` + `retain` / `release` bridge.

The CI matrix runs the test suite under `--mm:arc`, `--mm:orc`,
`--mm:atomicArc`, and `--mm:refc`. arc, orc, and atomicArc all use shared
atomic refcounts. refc is different: its GC heap is thread-local, so every
`retain` on thread A must be balanced by a `release` on thread A. If your
design hands retired pointers off to a background reclaim thread, that
pattern is fine on arc/orc/atomicArc but is undefined behaviour on refc.

For the longer rationale, the test recipes (TSAN/ASAN flags, stress shapes),
and the per-manager caveats, see
[`docs/safety-model.md`](docs/safety-model.md).

## Comparison to alternatives

A short tour of where DEBRA+ lands in the design space. Each of these is its
own deep topic; this is the headline-level shape of the trade-off.

- **Hazard pointers** publish per-thread "I am reading X" announcements that
  the reclaimer scans on every free. Memory bound is tight (O(threads ×
  hazards-per-thread)), but every read pays an explicit publish/scan cost.
  DEBRA+ trades a slightly looser bound (a small constant of recent epochs'
  worth of retires can sit in limbo) for a much cheaper read path.
- **RCU** uses quiescent-state detection to decide when a grace period has
  ended. It needs OS-level support to do that cheaply, which is why it is
  ubiquitous in the Linux kernel and rare in user space. DEBRA+ is purely a
  user-space protocol with no kernel cooperation; the cost is that it has
  to track epochs explicitly.
- **Manual atomic refcounting** (`std::shared_ptr`-style) avoids the
  bookkeeping entirely but pays an atomic RMW on every read, which makes
  truly lock-free traversal expensive on weakly-ordered architectures.
  DEBRA+'s read path is two SC stores per critical section, not per access.

For a longer treatment, the references below cover the academic background.

## Documentation

- [Documentation site](https://elijahr.github.io/nim-debra/latest/) — full
  guides, API reference, and design notes.
- [Getting started](https://elijahr.github.io/nim-debra/latest/guide/getting-started/),
  [concepts](https://elijahr.github.io/nim-debra/latest/guide/concepts/),
  and [integration guide](https://elijahr.github.io/nim-debra/latest/guide/integration/)
  are the most useful first reads.
- [`docs/safety-model.md`](docs/safety-model.md) — the bridge in detail and
  per-memory-manager notes.
- [`docs/design/2026-04-25-custom-atomics.md`](docs/design/2026-04-25-custom-atomics.md)
  — design rationale for the custom atomics module.

## Used by

- [lockfreequeues](https://github.com/elijahr/lockfreequeues) — lock-free
  queue implementations (SPSC, MPMC, bounded, unbounded) backed by nim-debra.

If you ship a project that depends on nim-debra, send a PR adding it here.

## References

- Trevor Brown. [Reclaiming Memory for Lock-Free Data Structures: There Has
  to Be a Better Way](https://arxiv.org/abs/1712.01044). 2017. The DEBRA+
  algorithm with signal-based neutralization for stalled threads.
- Keir Fraser. [Practical Lock-Freedom](https://www.cl.cam.ac.uk/techreports/UCAM-CL-TR-579.pdf).
  University of Cambridge Technical Report UCAM-CL-TR-579, 2004. Original
  epoch-based reclamation work that DEBRA+ builds on.
- [nim-typestates](https://github.com/elijahr/nim-typestates) — the
  compile-time typestate library used to enforce the DEBRA+ protocol.

## Contributing

Bug reports, fixes, and PRs are welcome. The development setup, test
matrix, and PR conventions live in [docs/contributing.md](docs/contributing.md).

## License

MIT. See the `license` field in [`debra.nimble`](debra.nimble).
