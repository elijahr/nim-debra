# nim-debra

DEBRA+ safe memory reclamation for lock-free data structures in Nim.

## What is this?

**nim-debra** implements the DEBRA+ algorithm (Distributed Epoch-Based Reclamation with Neutralization) for safe memory reclamation in lock-free concurrent data structures. It provides a compile-time typestate-enforced API that ensures correct usage of the reclamation protocol.

```nim
import debra
import std/atomics

# Define your node type using ref Obj pattern
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

# Critical section - pin to protect memory access
let pinned = unpinned(handle).pin()
# Create a managed node - GC won't collect until retired
let node = managed Node(value: 42)
# ... safely access lock-free data structures ...
discard pinned.unpin()

# Retire objects when they're no longer needed
let ready = retireReady(pinned)
let retired = ready.retire(node)
```

The typestate system ensures you cannot accidentally access memory outside a critical section, retire objects without being pinned, or perform operations in the wrong order. If it compiles, the protocol is correct.

## What is DEBRA+?

DEBRA+ is an epoch-based memory reclamation algorithm designed for lock-free data structures. Traditional garbage collection adds runtime overhead and unpredictable pauses. Manual memory management in concurrent code leads to use-after-free bugs and memory leaks.

DEBRA+ solves this by:

- **Epoch-based tracking**: Global epoch counter advances as threads complete operations
- **Pin/unpin protocol**: Threads pin the current epoch while accessing shared data
- **Safe reclamation**: Objects retired in epoch E can be freed once all threads have moved past E
- **Neutralization**: Signal-based mechanism handles stalled threads to bound memory usage

## Why typestates?

This library uses [nim-typestates](https://github.com/elijahr/nim-typestates) to enforce the DEBRA+ protocol at compile time:

- **Compile-time errors**: Invalid operation sequences fail at compile time with clear error messages
- **Self-documenting**: Types show what operations are valid in each state
- **Zero runtime cost**: All validation happens during compilation

For example, you cannot retire an object without being pinned:

```nim
let handle = registerThread(manager)
# This won't compile - must pin first!
# let ready = retireReady(handle)  # Error: handle is not Pinned

# This is correct:
let pinned = unpinned(handle).pin()
let ready = retireReady(pinned)
let retired = ready.retire(node)
```

## Key Features

- **Typestate-enforced API** - Invalid operation sequences fail at compile time
- **Signal-based neutralization** - Handles stalled threads for bounded memory usage
- **Limbo bags** - Thread-local retire queues organized in 64-object batches
- **Managed[T] wrapper** - Works with any `ref` type, integrates with Nim's GC
- **O(mn) memory bound** - Where m = threads, n = objects per epoch
- **Zero runtime overhead** - Typestate validation happens at compile time

## Memory Reclamation Workflow

1. **Manager initialization**: Create and initialize a `DebraManager[MaxThreads]`
2. **Thread registration**: Each thread registers to get a `ThreadHandle`
3. **Pin epoch**: Enter critical section with `pin()` to get `Pinned` state
4. **Access shared data**: Safely read/write lock-free data structures
5. **Retire objects**: Mark removed objects for reclamation with `retire()`
6. **Unpin epoch**: Exit critical section with `unpin()`
7. **Reclamation**: Background process reclaims objects from old epochs

## Installation

```bash
nimble install debra
```

Or add to your `.nimble` file:

```nim
requires "debra >= 0.1.0"
```

## Quick Links

- [Getting Started](guide/getting-started.md) - Tutorial walkthrough
- [Concepts](guide/concepts.md) - Understanding DEBRA+ algorithm
- [API Reference](api.md) - Generated API documentation

## References

### Foundational Papers

- [DEBRA+: Efficient Memory Reclamation (Brown, 2017)](https://arxiv.org/abs/1712.01044) - The DEBRA+ algorithm with signal-based neutralization
- [Epoch-Based Reclamation (Fraser, 2004)](https://www.cl.cam.ac.uk/techreports/UCAM-CL-TR-579.pdf) - Original epoch-based memory reclamation approach

### Related Projects

- [nim-typestates](https://github.com/elijahr/nim-typestates) - Compile-time typestate validation library used by nim-debra
- [lockfreequeues](https://github.com/elijahr/lockfreequeues) - Lock-free queue implementations using nim-debra for memory reclamation

## License

MIT
