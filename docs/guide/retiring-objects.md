# Retiring Objects

Understanding how to retire objects for safe reclamation.

## Overview

When you remove an object from a lock-free data structure, you cannot immediately free it - other threads might still be accessing it. Instead, you **retire** the object, marking it for later reclamation when safe.

## Basic Retirement

### Retire an Object

You must be pinned to retire objects:

```nim
let pinned = handle.pin()

# Remove node from lock-free queue
let node = queue.dequeue()

# Retire it for later reclamation
let ready = retireReady(pinned)
let retired = ready.retire(cast[pointer](node), nodeDestructor)

discard pinned.unpin()
```

The `retire()` call takes:

1. **Data pointer**: Pointer to the object being retired
2. **Destructor**: Function to call when reclaiming

## Destructors

### Destructor Signature

Destructors must have this signature:

```nim
proc myDestructor(p: pointer) {.nimcall.}
```

### Simple Destructor

For objects allocated with `alloc`:

```nim
proc simpleDestructor(p: pointer) {.nimcall.} =
  dealloc(p)
```

### Complex Destructor

For objects with cleanup needs:

```nim
type Node = object
  value: string
  data: seq[int]

proc nodeDestructor(p: pointer) {.nimcall.} =
  let node = cast[ptr Node](p)
  # Clean up resources
  node.value = ""
  node.data.setLen(0)
  # Free memory
  dealloc(node)
```

### Nil Destructor

If the object needs no cleanup (e.g., static memory):

```nim
let retired = ready.retire(somePtr, nil)
```

## Multiple Retirements

### Retiring Multiple Objects

To retire multiple objects while pinned:

```nim
let pinned = handle.pin()

var ready = retireReady(pinned)
for i in 0..<10:
  let node = queue.dequeue()
  let retired = ready.retire(cast[pointer](node), nodeDestructor)
  ready = retireReadyFromRetired(retired)

discard pinned.unpin()
```

The `retireReadyFromRetired()` function transitions back to `RetireReady` state for the next retirement.

## Limbo Bags

### How Retirement Works

Retired objects are added to thread-local limbo bags:

1. **Check current bag**: Is there a bag with space?
2. **Allocate if needed**: Create new bag if current is full (64 objects)
3. **Store object**: Add pointer and destructor to bag
4. **Record epoch**: Tag bag with current epoch
5. **Link bags**: Chain bags together for later reclamation

### Bag Structure

```
ThreadState.currentBag --> [Bag: epoch=5, count=23]
                           next |
                                v
                           [Bag: epoch=4, count=64]
                           next |
                                v
ThreadState.limboBagTail   [Bag: epoch=3, count=64]
```

### Bag Size

Each limbo bag holds up to 64 objects. When full, a new bag is allocated. This batching:

- Reduces allocation overhead
- Improves cache locality
- Simplifies reclamation

## Retirement and Epochs

### Epoch Tagging

Objects are retired at a specific epoch:

```nim
# Global epoch is 100
let pinned = handle.pin()  # Pins at epoch 100
let retired = retireReady(pinned).retire(ptr, destructor)
# Object tagged with epoch 100
```

### Reclamation Safety

Objects are safe to reclaim when all threads have advanced past their retirement epoch:

- Object retired at epoch 100
- All threads now at epoch 103+
- Safe to reclaim (no thread can be accessing it)

## Common Patterns

### Queue Node Retirement

```nim
type QueueNode = object
  value: int
  next: Atomic[ptr QueueNode]

proc destroyQueueNode(p: pointer) {.nimcall.} =
  dealloc(p)

proc dequeue(queue: var LockFreeQueue): int =
  let pinned = queue.handle.pin()

  # Dequeue operation (simplified)
  let head = queue.head.load(moAcquire)
  let value = head.value
  queue.head.store(head.next.load(moRelaxed), moRelease)

  # Retire old head
  let ready = retireReady(pinned)
  discard ready.retire(cast[pointer](head), destroyQueueNode)

  discard pinned.unpin()
  result = value
```

### List Node Retirement

```nim
proc removeNode(list: var LockFreeList, key: int) =
  let pinned = list.handle.pin()

  # Find and remove node
  var pred = list.head
  var curr = pred.next.load(moAcquire)

  while curr != nil:
    if curr.key == key:
      # Unlink node
      pred.next.store(curr.next.load(moRelaxed), moRelease)

      # Retire it
      let ready = retireReady(pinned)
      discard ready.retire(cast[pointer](curr), destroyListNode)
      break

    pred = curr
    curr = curr.next.load(moAcquire)

  discard pinned.unpin()
```

### Batch Retirement

```nim
proc clearAll(queue: var LockFreeQueue) =
  let pinned = queue.handle.pin()
  var ready = retireReady(pinned)

  var node = queue.head.load(moAcquire)
  while node != nil:
    let next = node.next.load(moRelaxed)

    # Retire this node
    let retired = ready.retire(cast[pointer](node), destroyQueueNode)
    ready = retireReadyFromRetired(retired)

    node = next

  queue.head.store(nil, moRelease)
  discard pinned.unpin()
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

### Retirement Timing

```nim
# WRONG - retire before unlinking
let retired = ready.retire(ptr, destructor)
queue.head.store(newHead, moRelease)

# RIGHT - retire after unlinking
queue.head.store(newHead, moRelease)
let retired = ready.retire(ptr, destructor)
```

Always unlink first, then retire. Otherwise other threads might access freed memory.

## Memory Overhead

Each retired object costs:

- Pointer: 8 bytes
- Destructor pointer: 8 bytes
- Total: 16 bytes per retired object

Plus limbo bag overhead:

- Bag header: ~32 bytes
- Holds 64 objects: 64 * 16 = 1024 bytes
- Overhead per object: ~1.5%

## Next Steps

- Learn about [reclamation](reclamation.md)
- Understand [neutralization](neutralization.md)
- See [integration examples](integration.md)
