# DEBRA+ Concepts

Understanding the core concepts behind DEBRA+ memory reclamation.

## The Memory Reclamation Problem

In lock-free data structures, traditional memory management approaches fail:

- **Garbage collection**: Adds unpredictable latency and runtime overhead
- **Reference counting**: Expensive atomic operations on every access
- **Manual management**: Race conditions lead to use-after-free or memory leaks

DEBRA+ provides a middle ground: explicit reclamation with safety guarantees.

## Epoch-Based Reclamation

DEBRA+ uses epochs to track when memory can be safely reclaimed:

1. **Global epoch counter**: Monotonically increasing integer
2. **Thread epochs**: Each active thread pins a specific epoch
3. **Retire queues**: Objects retired in each epoch
4. **Reclamation rule**: Objects retired in epoch E are safe to free once all threads have advanced past E

### Example Timeline

```
Time    Global  Thread1  Thread2  Action
----    ------  -------  -------  ------
t0      1       -        -        Start
t1      1       1        -        Thread1 pins epoch 1
t2      1       1        1        Thread2 pins epoch 1
t3      2       1        1        Epoch advances to 2
t4      2       2        1        Thread1 unpins, repins at 2
t5      2       2        2        Thread2 unpins, repins at 2
t6      2       2        2        Objects retired at epoch 1 can now be freed
```

## Pin/Unpin Protocol

Threads must pin the current epoch before accessing lock-free data structures:

```nim
# WRONG - not protected
let value = queue.dequeue()

# RIGHT - pinned during access
let pinned = unpinned(handle).pin()
let value = queue.dequeue()
discard pinned.unpin()
```

Pinning tells the reclamation system: "I might be accessing objects from this epoch."

## Limbo Bags

Retired objects are stored in thread-local limbo bags:

- Each bag holds up to 64 objects
- Bags are linked together forming a retire queue
- Managed objects use `GC_unref` for cleanup when reclaimed
- Organized by retirement epoch

### Limbo Bag Structure

```
Thread State
  currentBag --> [Bag: epoch=5, count=23] --> [Bag: epoch=4, count=64] --> ...
                         ^                            ^
                     limboBagHead                limboBagTail
```

## Safe Reclamation

Reclamation walks the limbo bags and frees objects from old epochs:

1. **Load epochs**: Read global epoch and all thread epochs
2. **Compute safe epoch**: Minimum of all pinned thread epochs
3. **Walk limbo bags**: From oldest (tail) toward newest (head)
4. **Reclaim eligible**: Free bags where `bag.epoch < safeEpoch - 1`
5. **Stop at barrier**: Once we hit a bag that's still unsafe, stop

## Neutralization

What if a thread stalls while pinned? It blocks reclamation indefinitely.

DEBRA+ solves this with **neutralization**:

1. **Detection**: During reclamation, detect threads pinned at old epochs
2. **Signal**: Send SIGUSR1 to stalled thread's OS process
3. **Handler**: Signal handler sets neutralization flag
4. **Acknowledgment**: Thread checks flag on unpin and handles it
5. **Recovery**: Thread acknowledges, allowing epoch to advance

### Neutralization Flow

```nim
# Thread 1: Pinned and working
let pinned = unpinned(handle).pin()
# ... long computation ...
let unpinResult = pinned.unpin()
case unpinResult.kind:
of uUnpinned:
  # Normal unpin
  discard
of uNeutralized:
  # We were neutralized - acknowledge it
  discard unpinResult.neutralized.acknowledge()
```

## Memory Bounds

DEBRA+ guarantees O(mn) memory overhead where:

- m = number of threads
- n = maximum objects retired per epoch per thread

Without neutralization, a stalled thread could accumulate unbounded memory. Neutralization ensures bounded growth.

## Typestate Enforcement

nim-debra uses compile-time typestates to enforce correct protocol usage:

- Cannot retire without being pinned
- Cannot pin without registering
- Must acknowledge neutralization before re-pinning

These invariants are checked at compile time, not runtime.

## Next Steps

- Learn about [thread registration](thread-registration.md)
- Understand [pin/unpin lifecycle](pin-unpin.md)
- Deep dive into [neutralization](neutralization.md)
