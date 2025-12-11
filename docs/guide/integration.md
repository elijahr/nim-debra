# Integration

Integrating nim-debra with lock-free data structures.

## Overview

This guide shows how to integrate nim-debra into lock-free data structures for safe memory reclamation.

## Basic Integration Pattern

1. Add manager reference to your data structure
2. Register threads on initialization
3. Pin during operations
4. Retire removed nodes
5. Periodically reclaim

## Lock-Free Stack

A complete Treiber stack implementation with DEBRA+ reclamation:

```nim
{% include-markdown "../../examples/lockfree_stack.nim" %}
```

[:material-file-code: View full source](https://github.com/elijahr/nim-debra/blob/main/examples/lockfree_stack.nim)

## Lock-Free Queue

A complete Michael-Scott queue implementation with DEBRA+ reclamation:

```nim
{% include-markdown "../../examples/lockfree_queue.nim" %}
```

[:material-file-code: View full source](https://github.com/elijahr/nim-debra/blob/main/examples/lockfree_queue.nim)

## Best Practices

### 1. Minimize Critical Section Duration

```nim
# GOOD - process outside critical section
let pinned = handle.pin()
let data = loadSharedData()
discard pinned.unpin()
processData(data)

# BAD - process inside critical section
let pinned = handle.pin()
let data = loadSharedData()
processData(data)
discard pinned.unpin()
```

### 2. Batch Retirements

Retire multiple objects in a single critical section when possible.

### 3. Handle Neutralization

Always handle the `uNeutralized` case from `unpin()`.

### 4. Periodic Reclamation

Don't reclaim after every operation - amortize the cost.

## Common Pitfalls

### Forgetting to Pin

```nim
# WRONG - accessing shared data without pinning
let value = queue.head.load(moAcquire).value

# RIGHT - pin before access
let pinned = handle.pin()
let value = queue.head.load(moAcquire).value
discard pinned.unpin()
```

### Retiring Too Early

```nim
# WRONG - retire before unlinking
discard ready.retire(ptr, destroy)
queue.head.store(newHead, moRelease)

# RIGHT - retire after unlinking
queue.head.store(newHead, moRelease)
discard ready.retire(ptr, destroy)
```

### Sharing Handles

```nim
# WRONG - sharing handle between threads
var sharedHandle: ThreadHandle[64]

# RIGHT - each thread has own handle
proc workerThread() {.thread.} =
  let handle = registerThread(manager)
```

## Performance Tips

1. **Batch operations**: Pin once for multiple operations
2. **Amortize reclamation**: Reclaim every N operations
3. **Dedicated reclaimer**: Use background thread for reclamation
4. **Minimize pinning**: Only pin when accessing shared data
5. **Avoid blocking**: Don't block while pinned

## Next Steps

- Review API reference
- Study the complete examples in the repository
- Benchmark your integration
