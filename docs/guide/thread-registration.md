# Thread Registration

Understanding thread registration lifecycle in DEBRA+.

## Overview

Each thread must register with the DEBRA manager before performing pin/unpin operations. Registration allocates a thread slot and provides a handle for all subsequent operations.

## Registration Process

### 1. Acquire Slot

The registration process begins by finding an available thread slot:

```nim
let handle = registerThread(addr manager)
```

This performs several steps:

1. Search for an unused slot in the thread array
2. Claim the slot by setting the OS thread ID
3. Initialize the slot's epoch and flags
4. Return a handle containing the slot index

### 2. Thread Handle

The returned `ThreadHandle` contains:

```nim
type ThreadHandle[MaxThreads: static int] = object
  idx: int  # Slot index in manager.threads array
  manager: ptr DebraManager[MaxThreads]
```

This handle is used for all subsequent operations:

- `handle.pin()` - Enter critical section
- `retireObject(pinned, ...)` - Retire objects
- Reclamation checks thread state via handle

## Thread Limits

The manager is created with a compile-time maximum thread count:

```nim
var manager: DebraManager[64]  # Support up to 64 threads
```

Attempting to register more threads than the limit will fail:

```nim
# This will raise an error if all 64 slots are occupied
let handle = registerThread(addr manager)
```

## Registration States

Thread registration follows a typestate protocol:

1. **Unregistered**: Thread has not registered yet
2. **SlotClaimed**: Thread has claimed a slot
3. **Registered**: Thread is fully registered and can pin

## Per-Thread State

Each thread slot maintains:

```nim
type ThreadState[MaxThreads: static int] = object
  epoch: Atomic[uint64]        # Current/pinned epoch
  pinned: Atomic[bool]         # Is thread pinned?
  neutralized: Atomic[bool]    # Neutralization flag
  osThreadId: Atomic[Pid]      # OS thread ID
  currentBag: ptr LimboBag     # Current limbo bag
  limboBagHead: ptr LimboBag   # Head of limbo bag list
  limboBagTail: ptr LimboBag   # Tail of limbo bag list
```

## Thread Deregistration

When a thread finishes, it should deregister:

```nim
# Future API - not yet implemented
let shutdown = handle.deregister()
```

Deregistration:

1. Ensures thread is unpinned
2. Reclaims any remaining limbo bags
3. Clears the OS thread ID to free the slot

## Registration Example

```nim
import debra

# Initialize manager
var manager: DebraManager[4]
discard uninitializedManager(addr manager).initialize()

# Worker thread
proc worker() {.thread.} =
  # Register this thread
  let handle = registerThread(addr manager)

  # Now we can use DEBRA operations
  for i in 0..<1000:
    let pinned = handle.pin()
    # ... work ...
    discard pinned.unpin()

  # Thread exits - deregistration automatic in future

# Start threads
var threads: array[4, Thread[void]]
for i in 0..<4:
  createThread(threads[i], worker)
for i in 0..<4:
  joinThreads(threads[i])
```

## Best Practices

1. **Register once per thread**: Don't register multiple times
2. **Keep handle alive**: Store the handle for the thread's lifetime
3. **Don't share handles**: Each thread needs its own handle
4. **Respect limits**: Don't exceed MaxThreads parameter

## Troubleshooting

### "No available thread slots"

All slots are occupied. Either:

- Increase `MaxThreads` when creating the manager
- Ensure threads deregister when done
- Check for thread leaks

### "Thread already registered"

A thread tried to register twice. Registration is per-thread, not per-operation.

## Next Steps

- Learn about [pin/unpin lifecycle](pin-unpin.md)
- Understand [retiring objects](retiring-objects.md)
