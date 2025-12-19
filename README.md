# nim-debra

[![CI](https://github.com/elijahr/nim-debra/actions/workflows/ci.yml/badge.svg)](https://github.com/elijahr/nim-debra/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Nim Version](https://img.shields.io/badge/nim-%E2%89%A5%202.2.0-orange.svg)](https://nim-lang.org/)
[![Documentation](https://img.shields.io/badge/docs-latest-green.svg)](https://elijahr.github.io/nim-debra/latest/)

DEBRA+ safe memory reclamation for lock-free data structures in Nim.

## Overview

nim-debra implements the DEBRA+ algorithm (Distributed Epoch-Based Reclamation with Neutralization) as a generic library for safe memory reclamation in lock-free data structures.

## Features

- **Managed[T] wrapper** - Works with any `ref` type, integrates with Nim's GC
- **Typestate-enforced** - Correct operation sequencing validated at compile-time
- **Signal-based neutralization** - Handles stalled threads for bounded memory
- **O(mn) memory bound** - Where m = threads, n = hazardous pointers per thread

## Lock-Free Guarantees

nim-debra is designed for lock-free concurrent data structures. To ensure your code is truly lock-free:

### Compile-Time Checks

Nim's atomics module supports `-d:nimEnforceLockFreeAtomics` to emit compile-time errors when using types that would fall back to spinlocks.

nim-debra adds additional checks by default:

- **Managed[ref T] on arc/orc**: Errors by default since `Atomic[ref T]` uses spinlocks. Use `-d:allowSpinlockManagedRef` to allow.
- **Generic lock-free enforcement**: Use `-d:nimEnforceLockFreeAtomics` to catch other spinlock fallbacks.

### Verifying Lock-Free Status

Use `isLockFree` to check types at compile-time:

```nim
import std/atomics

static:
  assert int.isLockFree           # true on all platforms
  assert pointer.isLockFree       # true on all platforms
  assert uint64.isLockFree        # true on 64-bit platforms

  # ref types are NOT lock-free on arc/orc!
  when defined(gcArc) or defined(gcOrc):
    doAssert not (ref object).isLockFree
```

### Recommended Patterns for Lock-Free Code

For maximum portability and guaranteed lock-free operation:

- **Use `ptr T`** with `alloc0`/`dealloc` for data structure nodes
- **Use pointer-based retire**: `retire(ptr, destructor)` instead of `retire(Managed[ref T])`
- **Test with multiple memory managers**: Test with both `--mm:arc` and `--mm:refc`
- **Enable enforcement in CI**: Use `-d:nimEnforceLockFreeAtomics` in continuous integration

Example lock-free node:

```nim
type
  NodeObj = object
    value: int
    next: Atomic[ptr NodeObj]

# Allocate
let node = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
node.value = 42

# Retire with custom destructor
proc destroyNode(p: pointer) {.nimcall.} =
  dealloc(p)

let ready = retireReady(pinned)
discard ready.retire(node, destroyNode)
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
import std/atomics

# Define node type using ref Obj pattern for self-reference
type
  NodeObj = object
    value: int
    next: Atomic[Managed[ref NodeObj]]
  Node = ref NodeObj

# Initialize manager (one per process)
var manager = initDebraManager[64]()
setGlobalManager(addr manager)

# Register thread (once per thread)
let handle = registerThread(manager)

# Pin for critical section
let pinned = unpinned(handle).pin()

# Create managed objects - GC won't collect until retired
let node = managed Node(value: 42)

# Retire objects for later reclamation
let ready = retireReady(pinned)
discard ready.retire(node)

# Unpin when leaving critical section
discard pinned.unpin()

# Explicitly reclaim when appropriate
let reclaim = reclaimStart(addr manager).loadEpochs().checkSafe()
if reclaim.kind == rReclaimReady:
  discard reclaim.reclaimready.tryReclaim()
```

## References

- [DEBRA+ Paper](https://arxiv.org/abs/1712.01044)
