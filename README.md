# nim-debra

DEBRA+ safe memory reclamation for lock-free data structures in Nim.

## Overview

nim-debra implements the DEBRA+ algorithm (Distributed Epoch-Based Reclamation with Neutralization) as a generic library for safe memory reclamation in lock-free data structures.

## Features

- **Generic** - Works with any pointer type
- **Typestate-enforced** - Correct operation sequencing validated at compile-time
- **Signal-based neutralization** - Handles stalled threads for bounded memory
- **O(mn) memory bound** - Where m = threads, n = hazardous pointers per thread

## Documentation

Full documentation is available at **[elijahr.github.io/nim-debra](https://elijahr.github.io/nim-debra/)**.

- [Getting Started](https://elijahr.github.io/nim-debra/guide/getting-started/)
- [Core Concepts](https://elijahr.github.io/nim-debra/guide/concepts/)
- [Thread Registration](https://elijahr.github.io/nim-debra/guide/thread-registration/)
- [Pin/Unpin Operations](https://elijahr.github.io/nim-debra/guide/pin-unpin/)
- [Retiring Objects](https://elijahr.github.io/nim-debra/guide/retiring-objects/)
- [Reclamation](https://elijahr.github.io/nim-debra/guide/reclamation/)
- [Neutralization](https://elijahr.github.io/nim-debra/guide/neutralization/)
- [Integration Guide](https://elijahr.github.io/nim-debra/guide/integration/)

## Installation

```sh
nimble install debra
```

## Quick Start

```nim
import debra

# Initialize manager (one per process)
var manager = initDebraManager[64]()
setGlobalManager(addr manager)

# Register thread (once per thread)
let handle = registerThread(manager)

# Critical section
let pinned = handle.pin()
# ... access shared data ...
discard pinned.unpin()
```

## References

- [DEBRA+ Paper](https://arxiv.org/abs/1712.01044)
