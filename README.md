# nim-debra

[![CI](https://github.com/elijahr/nim-debra/actions/workflows/ci.yml/badge.svg)](https://github.com/elijahr/nim-debra/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Nim Version](https://img.shields.io/badge/nim-%E2%89%A5%202.2.0-orange.svg)](https://nim-lang.org/)
[![Documentation](https://img.shields.io/badge/docs-latest-green.svg)](https://elijahr.github.io/nim-debra/latest/)

DEBRA+ safe memory reclamation for lock-free data structures in Nim.

## Overview

nim-debra implements the DEBRA+ algorithm (Distributed Epoch-Based Reclamation with Neutralization) as a generic library for safe memory reclamation in lock-free data structures.

## Features

- **`retain` / `release` bridge** - Stores `ref` types in `Atomic[ptr T]` slots without falling back to spinlocks
- **Typestate-enforced** - Correct operation sequencing validated at compile-time
- **Signal-based neutralization** - Handles stalled threads for bounded memory
- **O(mn) memory bound** - Where m = threads, n = hazardous pointers per thread

## Lock-Free Guarantees

nim-debra is designed for lock-free concurrent data structures. The library's
own atomics module (`debra/atomics`) refuses to compile `Atomic[ref T]` and
any type that is not trivially copyable, eliminating the most common
spinlock-fallback footgun at compile time. Rationale and full design notes
live in [`docs/design/2026-04-25-custom-atomics.md`](docs/design/2026-04-25-custom-atomics.md).

To store a `ref T` atomically, convert it to `ptr T` with `retain` and pair
each `retain` with exactly one `release` (typically via the destructor returned
by `releaseDestructor[T]()` handed to `retire`).

### Verifying Lock-Free Status

`debra/atomics` exposes `isLockFree` for compile-time checks:

```nim
import debra/atomics

static:
  assert int.isLockFree           # true on all platforms
  assert pointer.isLockFree       # true on all platforms
  assert uint64.isLockFree        # true on 64-bit platforms
```

`Atomic[ref T]` does not compile at all; the error message points you at
`Atomic[ptr T]` plus `retain`/`release`.

### Recommended Patterns for Lock-Free Code

- **Store `Atomic[ptr T]`** in node fields, not `Atomic[ref T]`
- **Use `retain` to GC-pin a `ref`** and obtain a raw pointer for atomic storage
- **Pair every `retain` with `releaseDestructor[T]()`** when you `retire(p, dtor)`
- **Test with multiple memory managers**: Test with both `--mm:arc`, `--mm:orc`, and `--mm:refc`

Example lock-free node:

```nim
import debra
import debra/atomics

type
  NodeObj = object
    value: int
    next: Atomic[ptr NodeObj]
  Node = ref NodeObj

# `retain` increments the GC ref count and returns a raw ptr suitable
# for atomic storage. Pair it with `releaseDestructor[NodeObj]()` at retire.
let node = retain Node(value: 42)

let ready = retireReady(pinned)
discard ready.retire(cast[pointer](node), releaseDestructor[NodeObj]())
```

## Documentation

Full documentation is available at **[elijahr.github.io/nim-debra](https://elijahr.github.io/nim-debra/latest/)**.

- [Getting Started](https://elijahr.github.io/nim-debra/latest/guide/getting-started/)
- [Core Concepts](https://elijahr.github.io/nim-debra/latest/guide/concepts/)
- [Thread Registration](https://elijahr.github.io/nim-debra/latest/guide/thread-registration/)
- [Pin/Unpin Operations](https://elijahr.github.io/nim-debra/latest/guide/pin-unpin/)
- [Retiring Objects](https://elijahr.github.io/nim-debra/latest/guide/retiring-objects/)
- [Reclamation](https://elijahr.github.io/nim-debra/latest/guide/reclamation/)
- [Neutralization](https://elijahr.github.io/nim-debra/latest/guide/neutralization/)
- [Integration Guide](https://elijahr.github.io/nim-debra/latest/guide/integration/)

## Installation

```sh
nimble install debra
```

## Quick Start

### High-Level Convenience API

For simple retire + reclaim workflows:

```nim
import debra

type
  NodeObj = object
    value: int
    next: ptr NodeObj

# Custom destructor
proc destroyNode(p: pointer) {.nimcall.} =
  dealloc(p)

# Initialize manager and register thread
var manager = initDebraManager[64]()
setGlobalManager(addr manager)
let handle = registerThread(manager)

# Allocate node
let node = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
node.value = 42

# Retire and try to reclaim in one call
retireAndReclaim(handle, node, destroyNode)
```

### Low-Level Typestate API

For batching operations or fine-grained control:

```nim
import debra
import debra/atomics

# Self-referential node: `Atomic[ptr NodeObj]` lets the type checker
# resolve the recursive shape (`ptr` is opaque to it).
type
  NodeObj = object
    value: int
    next: Atomic[ptr NodeObj]
  Node = ref NodeObj

# Initialize manager (one per process)
var manager = initDebraManager[64]()
setGlobalManager(addr manager)

# Register thread (once per thread)
let handle = registerThread(manager)

# Pin for critical section
let pinned = unpinned(handle).pin()

# Retain a ref to GC-pin it and get a raw pointer for atomic storage.
let node = retain Node(value: 42)

# Retire the pointer; `releaseDestructor[NodeObj]()` will GC_unref it
# once the epoch is safe.
let ready = retireReady(pinned)
discard ready.retire(cast[pointer](node), releaseDestructor[NodeObj]())

# Unpin when leaving critical section
discard pinned.unpin()

# Explicitly reclaim when appropriate
let reclaim = reclaimStart(addr manager).loadEpochs().checkSafe()
if reclaim.kind == rReclaimReady:
  discard reclaim.reclaimready.tryReclaim()
```

## References

- [DEBRA+ Paper](https://arxiv.org/abs/1712.01044)
