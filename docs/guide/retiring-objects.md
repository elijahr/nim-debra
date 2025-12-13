# Retiring Objects

Understanding how to retire objects for safe reclamation.

## State Machine

![Retire Typestate](../assets/diagrams/retire.svg)

## Overview

When you remove an object from a lock-free data structure, you cannot immediately free it - other threads might still be accessing it. Instead, you **retire** the object, marking it for later reclamation when safe.

## Basic Retirement

You must be pinned to retire objects. The `retire()` call takes:

1. **Data pointer**: Pointer to the object being retired
2. **Destructor**: Function to call when reclaiming

## Single Object Retirement

```nim
{% include-markdown "../../examples/retire_single.nim" %}
```

[:material-file-code: View full source](https://github.com/elijahr/nim-debra/blob/main/examples/retire_single.nim)

## Multiple Object Retirement

When retiring multiple objects in a single critical section, use `retireReadyFromRetired()` to chain retirements:

```nim
{% include-markdown "../../examples/retire_multiple.nim" %}
```

[:material-file-code: View full source](https://github.com/elijahr/nim-debra/blob/main/examples/retire_multiple.nim)

## Destructors

Destructors must have this signature:

```nim
proc myDestructor(p: pointer) {.nimcall.}
```

For objects allocated with `alloc`:

```nim
proc simpleDestructor(p: pointer) {.nimcall.} =
  dealloc(p)
```

If the object needs no cleanup (e.g., static memory), pass `nil` as the destructor.

## Limbo Bags

Retired objects are stored in thread-local limbo bags:

- Each bag holds up to 64 objects
- Bags are chained together by epoch
- Reclamation walks bags from oldest to newest

## Retirement Timing

Always unlink first, then retire:

```nim
# RIGHT - retire after unlinking
queue.head.store(newHead, moRelease)
let ready = retireReady(pinned)
discard ready.retire(oldHead, destroy)

# WRONG - retire before unlinking (unsafe!)
let ready = retireReady(pinned)
discard ready.retire(oldHead, destroy)
queue.head.store(newHead, moRelease)
```

## Best Practices

### Do Retire Objects That:

- Were removed from shared data structures
- Are no longer reachable via shared pointers
- Might still be accessed by concurrent threads

### Don't Retire Objects That:

- Are still reachable in the data structure
- Are local to the current thread (just free them)
- Are static/global (they're never freed)

## Memory Overhead

Each retired object costs:

- Pointer: 8 bytes
- Destructor pointer: 8 bytes
- Limbo bag overhead: ~1.5% per object

## Next Steps

- Learn about [reclamation](reclamation.md)
- Understand [neutralization](neutralization.md)
- See [integration examples](integration.md)
