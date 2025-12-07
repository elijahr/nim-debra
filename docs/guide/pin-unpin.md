# Pin/Unpin Protocol

Understanding the pin/unpin lifecycle for critical sections.

## Overview

The pin/unpin protocol marks critical sections where threads access lock-free data structures. Pinning prevents reclamation of objects from the current epoch.

## Pin Operation

### What Pin Does

When you call `handle.pin()`:

1. **Load global epoch**: Read the current global epoch counter
2. **Clear neutralization**: Reset the neutralization flag
3. **Store epoch**: Write epoch to thread's epoch slot
4. **Set pinned flag**: Mark thread as pinned

```nim
let pinned = handle.pin()
```

Returns a `Pinned[MaxThreads]` state that enables further operations.

### Memory Ordering

Pin uses acquire-release semantics:

- **Acquire**: Ensures prior writes by other threads are visible
- **Release**: Ensures our writes are visible to other threads

This establishes the happens-before relationship needed for safe concurrent access.

## Unpin Operation

### What Unpin Does

When you call `pinned.unpin()`:

1. **Clear pinned flag**: Mark thread as no longer pinned
2. **Check neutralization**: Read the neutralization flag
3. **Return result**: Either `Unpinned` or `Neutralized` state

```nim
let result = pinned.unpin()
case result.kind:
of uUnpinned:
  # Normal unpin - continue
  discard
of uNeutralized:
  # We were neutralized - must acknowledge
  let unpinned = result.neutralized.acknowledge()
```

### Neutralization Handling

If the thread was neutralized while pinned (received SIGUSR1), unpin returns a `Neutralized` state. You must acknowledge this before re-pinning:

```nim
let result = pinned.unpin()
if result.kind == uNeutralized:
  let unpinned = result.neutralized.acknowledge()
  # Now can pin again
```

## Critical Section Pattern

Standard pattern for critical sections:

```nim
# Enter critical section
let pinned = handle.pin()

# Access lock-free data structures
let value = queue.dequeue()
let node = list.search(key)

# Exit critical section
let result = pinned.unpin()

# Handle neutralization if needed
if result.kind == uNeutralized:
  discard result.neutralized.acknowledge()
```

## What Can You Do While Pinned?

While pinned, you can:

- **Read** shared memory from lock-free structures
- **Perform CAS operations** to modify shared state
- **Retire objects** that have been removed
- **Access multiple structures** in same critical section

```nim
let pinned = handle.pin()

# Multiple operations in one critical section
let value1 = queue1.dequeue()
let value2 = queue2.dequeue()

# Retire both
let ready1 = retireReady(pinned)
let retired1 = ready1.retire(value1.ptr, destroyer1)
let ready2 = retireReadyFromRetired(retired1)
let retired2 = ready2.retire(value2.ptr, destroyer2)

discard pinned.unpin()
```

## What You Cannot Do While Pinned

Avoid these while pinned:

- **Blocking operations**: Don't hold locks, wait on condition variables
- **Long computations**: Keep critical sections short
- **I/O operations**: Don't do file/network I/O while pinned
- **Sleeping**: Don't call sleep or delay functions

Why? Pinning blocks epoch advancement and prevents reclamation. Long critical sections waste memory.

## Critical Section Duration

Keep critical sections minimal:

```nim
# BAD - long critical section
let pinned = handle.pin()
let node = queue.dequeue()
processNode(node)  # Long processing
saveToDatabase(node)  # I/O operation
discard pinned.unpin()

# GOOD - minimal critical section
let pinned = handle.pin()
let node = queue.dequeue()
discard pinned.unpin()

# Process outside critical section
processNode(node)
saveToDatabase(node)
```

## Nested Critical Sections

Currently, nested pin/unpin is not supported:

```nim
# NOT SUPPORTED
let pinned1 = handle.pin()
let pinned2 = handle.pin()  # Compile error!
```

If you need to exit and re-enter, unpin first:

```nim
let pinned1 = handle.pin()
let value1 = queue1.dequeue()
discard pinned1.unpin()

# Re-pin for second operation
let pinned2 = handle.pin()
let value2 = queue2.dequeue()
discard pinned2.unpin()
```

## Performance Considerations

Pin/unpin overhead:

- **Pin**: 1 atomic load, 1 atomic store, 2 relaxed stores (~10-20ns)
- **Unpin**: 1 relaxed store, 1 atomic load (~5-10ns)
- **Total**: ~15-30ns per critical section

This is negligible compared to lock-free operation costs. However:

- Don't pin/unpin in tight loops if not needed
- Batch operations when possible
- Keep critical sections focused

## Typestate Guarantees

The typestate system enforces:

1. **Cannot retire unpinned**: Must be in `Pinned` state to retire objects
2. **Cannot double-pin**: Once pinned, cannot pin again without unpinning
3. **Must acknowledge neutralization**: Cannot pin after neutralization without acknowledging

These are compile-time guarantees - if it compiles, the protocol is correct.

## Next Steps

- Learn about [retiring objects](retiring-objects.md)
- Understand [neutralization](neutralization.md)
- See [integration examples](integration.md)
