# Pin/Unpin Protocol

Understanding the pin/unpin lifecycle for critical sections.

## Overview

The pin/unpin protocol marks critical sections where threads access lock-free data structures. Pinning prevents reclamation of objects from the current epoch.

## Pin Operation

When you call `pin()`:

1. **Load global epoch**: Read the current global epoch counter
2. **Clear neutralization**: Reset the neutralization flag
3. **Store epoch**: Write epoch to thread's epoch slot
4. **Set pinned flag**: Mark thread as pinned

## Unpin Operation

When you call `unpin()`:

1. **Clear pinned flag**: Mark thread as no longer pinned
2. **Check neutralization**: Read the neutralization flag
3. **Return result**: Either `Unpinned` or `Neutralized` state

## Critical Section Example

The following example demonstrates pin/unpin patterns and neutralization handling:

```nim
{% include-markdown "../../examples/pin_unpin.nim" %}
```

[:material-file-code: View full source](https://github.com/elijahr/nim-debra/blob/main/examples/pin_unpin.nim)

## What You Can Do While Pinned

- **Read** shared memory from lock-free structures
- **Perform CAS operations** to modify shared state
- **Retire objects** that have been removed
- **Access multiple structures** in same critical section

## What You Cannot Do While Pinned

Avoid these while pinned:

- **Blocking operations**: Don't hold locks, wait on condition variables
- **Long computations**: Keep critical sections short
- **I/O operations**: Don't do file/network I/O while pinned
- **Sleeping**: Don't call sleep or delay functions

Why? Pinning blocks epoch advancement and prevents reclamation. Long critical sections waste memory.

## Typestate Guarantees

The typestate system enforces:

1. **Cannot retire unpinned**: Must be in `Pinned` state to retire objects
2. **Cannot double-pin**: Once pinned, cannot pin again without unpinning
3. **Must acknowledge neutralization**: Cannot pin after neutralization without acknowledging

These are compile-time guarantees - if it compiles, the protocol is correct.

## Performance Considerations

Pin/unpin overhead:

- **Pin**: ~10-20ns (1 atomic load, 1 atomic store, 2 relaxed stores)
- **Unpin**: ~5-10ns (1 relaxed store, 1 atomic load)

This is negligible compared to lock-free operation costs.

## Next Steps

- Learn about [retiring objects](retiring-objects.md)
- Understand [neutralization](neutralization.md)
- See [integration examples](integration.md)
