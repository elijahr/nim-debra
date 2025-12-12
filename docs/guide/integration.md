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

## Typestate Composition

DEBRA is implemented using [nim-typestates](https://github.com/elijahr/nim-typestates). This means you can compose DEBRA's memory safety guarantees with your own application-level typestates.

This enables "correct by design" algorithms:

1. **Your algorithm's states** - Enforced at compile time (e.g., Empty/NonEmpty stack)
2. **DEBRA's protocol** - Pin/unpin/retire sequence enforced at compile time
3. **Bridges** - Connect your states to other typestates (e.g., popped items enter a processing pipeline)

### Library Typestates Are Pluggable

When you `import debra`, you get access to DEBRA's typestates:

- `Unpinned[N]` / `Pinned[N]` / `Neutralized[N]` - Epoch guard states
- `RetireReady[N]` / `Retired[N]` - Retirement states
- `ReclaimStart[N]` / `EpochsLoaded[N]` / `ReclaimReady[N]` / `ReclaimBlocked[N]` - Reclamation states

Your code uses these directly. The compiler verifies you follow the protocol.

### Example: Item Processing Pipeline

Define a typestate for processing items after they leave the data structure:

```nim
{% include-markdown "../../examples/item_processing.nim" %}
```

[:material-file-code: View source](https://github.com/elijahr/nim-debra/blob/main/examples/item_processing.nim)

### Example: Stack with Typestate Composition

Combine stack states, DEBRA states, and bridges to the item processing pipeline:

```nim
{% include-markdown "../../examples/lockfree_stack_typestates.nim" %}
```

[:material-file-code: View source](https://github.com/elijahr/nim-debra/blob/main/examples/lockfree_stack_typestates.nim)

### Key Points

- **Nested enforcement**: DEBRA's `pin()`/`unpin()` happens inside your `push()`/`pop()` - both are type-checked
- **Bridges connect state machines**: Popped items flow from stack states into processing states
- **Zero runtime cost**: All validation is compile-time
- **Module-qualified syntax**: Use `module.Typestate.State` in bridges for clarity

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

Always handle the `uNeutralized` case from `unpin()`. This is a required pattern - neutralization occurs when the epoch advances during a critical section, and you must acknowledge it before re-pinning.

```nim
let unpinResult = pinned.unpin()
case unpinResult.kind:
of uUnpinned:
  # Normal unpin - continue
  discard
of uNeutralized:
  # Was neutralized - must acknowledge before re-pinning
  discard unpinResult.neutralized.acknowledge()
```

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
