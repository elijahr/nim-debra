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

# Critical section
let pinned = unpinned(handle).pin()

# Create managed objects - GC won't collect until retired
let node = managed Node(value: 42)

# Retire objects for later reclamation
let ready = retireReady(pinned)
discard ready.retire(node)

discard pinned.unpin()
```

## References

- [DEBRA+ Paper](https://arxiv.org/abs/1712.01044)
