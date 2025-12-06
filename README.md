# nim-debra

DEBRA+ safe memory reclamation for lock-free data structures in Nim.

## Overview

nim-debra implements the DEBRA+ algorithm (Distributed Epoch-Based Reclamation with Neutralization) as a generic library for safe memory reclamation in lock-free data structures.

## Features

- **Generic** - Works with any pointer type
- **Typestate-enforced** - Correct operation sequencing validated at compile-time
- **Signal-based neutralization** - Handles stalled threads for bounded memory
- **O(mn) memory bound** - Where m = threads, n = hazardous pointers per thread

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
