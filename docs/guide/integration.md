# Integration

Integrating nim-debra with lock-free data structures.

## Overview

This guide shows how to integrate nim-debra into lock-free data structures for safe memory reclamation.

## Basic Integration Pattern

### 1. Add DEBRA Manager to Structure

```nim
import debra

type LockFreeQueue[T] = object
  head: Atomic[ptr Node[T]]
  tail: Atomic[ptr Node[T]]
  manager: ptr DebraManager[64]  # Add manager reference
  handle: ThreadHandle[64]       # Per-thread handle
```

### 2. Initialize Manager

```nim
proc initLockFreeQueue[T](manager: ptr DebraManager[64]): LockFreeQueue[T] =
  result.head.store(nil, moRelaxed)
  result.tail.store(nil, moRelaxed)
  result.manager = manager
  result.handle = registerThread(manager)
```

### 3. Pin During Operations

```nim
proc enqueue[T](queue: var LockFreeQueue[T], value: T) =
  let pinned = queue.handle.pin()

  # Lock-free enqueue operation
  let newNode = allocNode(value)
  # ... CAS operations ...

  discard pinned.unpin()
```

### 4. Retire Removed Nodes

```nim
proc dequeue[T](queue: var LockFreeQueue[T]): Option[T] =
  let pinned = queue.handle.pin()

  let head = queue.head.load(moAcquire)
  if head == nil:
    discard pinned.unpin()
    return none(T)

  let next = head.next.load(moRelaxed)
  queue.head.store(next, moRelease)

  # Retire old head
  let ready = retireReady(pinned)
  discard ready.retire(cast[pointer](head), destroyNode[T])

  let result = some(head.value)
  discard pinned.unpin()
  result
```

## Complete Example: Lock-Free Stack

```nim
import debra
import std/[atomics, options]

# Node type
type
  Node[T] = object
    value: T
    next: Atomic[ptr Node[T]]

  LockFreeStack[T] = object
    top: Atomic[ptr Node[T]]
    manager: ptr DebraManager[64]
    handle: ThreadHandle[64]

# Node destructor
proc destroyNode[T](p: pointer) {.nimcall.} =
  let node = cast[ptr Node[T]](p)
  dealloc(node)

# Initialize stack
proc initStack[T](manager: ptr DebraManager[64]): LockFreeStack[T] =
  result.top.store(nil, moRelaxed)
  result.manager = manager
  result.handle = registerThread(manager)

# Push operation
proc push[T](stack: var LockFreeStack[T], value: T) =
  let pinned = stack.handle.pin()

  let newNode = cast[ptr Node[T]](alloc(sizeof(Node[T])))
  newNode.value = value

  var done = false
  while not done:
    let oldTop = stack.top.load(moAcquire)
    newNode.next.store(oldTop, moRelaxed)

    if stack.top.compareExchange(oldTop, newNode, moRelease, moRelaxed):
      done = true

  discard pinned.unpin()

# Pop operation
proc pop[T](stack: var LockFreeStack[T]): Option[T] =
  let pinned = stack.handle.pin()

  var done = false
  var result: Option[T] = none(T)

  while not done:
    let oldTop = stack.top.load(moAcquire)

    if oldTop == nil:
      done = true
    else:
      let next = oldTop.next.load(moRelaxed)

      if stack.top.compareExchange(oldTop, next, moRelease, moRelaxed):
        result = some(oldTop.value)

        # Retire old top
        let ready = retireReady(pinned)
        discard ready.retire(cast[pointer](oldTop), destroyNode[T])

        done = true

  discard pinned.unpin()
  result

# Usage
var manager: DebraManager[64]
discard uninitializedManager(addr manager).initialize()

var stack = initStack[int](addr manager)
stack.push(42)
echo stack.pop()  # Some(42)
```

## Lock-Free Queue Example

```nim
import debra
import std/[atomics, options]

type
  QueueNode[T] = object
    value: T
    next: Atomic[ptr QueueNode[T]]

  LockFreeQueue[T] = object
    head: Atomic[ptr QueueNode[T]]
    tail: Atomic[ptr QueueNode[T]]
    manager: ptr DebraManager[64]
    handle: ThreadHandle[64]

proc destroyQueueNode[T](p: pointer) {.nimcall.} =
  dealloc(p)

proc initQueue[T](manager: ptr DebraManager[64]): LockFreeQueue[T] =
  # Sentinel node
  let sentinel = cast[ptr QueueNode[T]](alloc(sizeof(QueueNode[T])))
  sentinel.next.store(nil, moRelaxed)

  result.head.store(sentinel, moRelaxed)
  result.tail.store(sentinel, moRelaxed)
  result.manager = manager
  result.handle = registerThread(manager)

proc enqueue[T](queue: var LockFreeQueue[T], value: T) =
  let pinned = queue.handle.pin()

  let newNode = cast[ptr QueueNode[T]](alloc(sizeof(QueueNode[T])))
  newNode.value = value
  newNode.next.store(nil, moRelaxed)

  var done = false
  while not done:
    let tail = queue.tail.load(moAcquire)
    let next = tail.next.load(moAcquire)

    if next == nil:
      if tail.next.compareExchange(nil, newNode, moRelease, moRelaxed):
        discard queue.tail.compareExchange(tail, newNode, moRelease, moRelaxed)
        done = true
    else:
      discard queue.tail.compareExchange(tail, next, moRelease, moRelaxed)

  discard pinned.unpin()

proc dequeue[T](queue: var LockFreeQueue[T]): Option[T] =
  let pinned = queue.handle.pin()

  var done = false
  var result: Option[T] = none(T)

  while not done:
    let head = queue.head.load(moAcquire)
    let tail = queue.tail.load(moAcquire)
    let next = head.next.load(moAcquire)

    if next != nil:
      if queue.head.compareExchange(head, next, moRelease, moRelaxed):
        result = some(next.value)

        # Retire old head
        let ready = retireReady(pinned)
        discard ready.retire(cast[pointer](head), destroyQueueNode[T])

        done = true
    else:
      done = true  # Queue is empty

  discard pinned.unpin()
  result
```

## Multi-Threaded Integration

### Shared Manager, Per-Thread Handles

```nim
var globalManager: DebraManager[64]

proc initGlobal() =
  discard uninitializedManager(addr globalManager).initialize()

proc workerThread(id: int) {.thread.} =
  # Each thread registers once
  let handle = registerThread(addr globalManager)

  var stack = LockFreeStack[int]()
  stack.manager = addr globalManager
  stack.handle = handle  # Use this thread's handle

  for i in 0..<1000:
    stack.push(i)
    discard stack.pop()

# Main
initGlobal()
var threads: array[8, Thread[int]]
for i in 0..<8:
  createThread(threads[i], workerThread, i)
for i in 0..<8:
  joinThreads(threads[i])
```

## Reclamation Strategies

### Background Reclamation Thread

```nim
var shouldStop = false

proc reclaimerThread() {.thread.} =
  while not shouldStop:
    let result = reclaimStart(addr globalManager)
      .loadEpochs()
      .checkSafe()

    if result.kind == rReclaimReady:
      discard result.reclaimready.tryReclaim()

    sleep(10)  # 10ms interval

var reclaimer: Thread[void]
createThread(reclaimer, reclaimerThread)
```

### Per-Operation Reclamation

```nim
var opsSinceReclaim = 0

proc push[T](stack: var LockFreeStack[T], value: T) =
  # ... normal push operation ...

  inc opsSinceReclaim
  if opsSinceReclaim >= 100:
    opsSinceReclaim = 0
    let result = reclaimStart(stack.manager)
      .loadEpochs()
      .checkSafe()
    if result.kind == rReclaimReady:
      discard result.reclaimready.tryReclaim()
```

## Best Practices

### 1. Minimize Critical Section Duration

```nim
# GOOD
proc operation() =
  let pinned = handle.pin()
  let data = loadSharedData()
  discard pinned.unpin()
  processData(data)  # Outside critical section

# BAD
proc operation() =
  let pinned = handle.pin()
  let data = loadSharedData()
  processData(data)  # Inside critical section!
  discard pinned.unpin()
```

### 2. Batch Retirements

```nim
proc clearAll() =
  let pinned = handle.pin()
  var ready = retireReady(pinned)

  while true:
    let node = removeNode()
    if node == nil: break

    let retired = ready.retire(cast[pointer](node), destroy)
    ready = retireReadyFromRetired(retired)

  discard pinned.unpin()
```

### 3. Handle Neutralization

```nim
proc robustOperation() =
  var done = false
  while not done:
    let pinned = handle.pin()
    performOperation()
    let result = pinned.unpin()

    case result.kind:
    of uUnpinned:
      done = true
    of uNeutralized:
      discard result.neutralized.acknowledge()
      # Will retry
```

### 4. Periodic Reclamation

```nim
const ReclaimInterval = 100

var opsCount = 0

proc afterOperation() =
  inc opsCount
  if opsCount mod ReclaimInterval == 0:
    tryReclaim()
```

## Debugging Integration

### Check Manager State

```nim
proc dumpManagerState(manager: ptr DebraManager[64]) =
  echo "Global epoch: ", manager.globalEpoch.load(moRelaxed)
  echo "Active threads: ", manager.activeThreadMask.load(moRelaxed)

  for i in 0..<64:
    if manager.threads[i].pinned.load(moRelaxed):
      echo "  Thread ", i, ": epoch=", manager.threads[i].epoch.load(moRelaxed)
```

### Track Memory Usage

```nim
proc countRetiredObjects(manager: ptr DebraManager[64]): int =
  for i in 0..<64:
    var bag = manager.threads[i].limboBagHead
    while bag != nil:
      result += bag.count
      bag = bag.next
```

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
let ready = retireReady(pinned)
discard ready.retire(ptr, destroy)
queue.head.store(newHead, moRelease)

# RIGHT - retire after unlinking
queue.head.store(newHead, moRelease)
let ready = retireReady(pinned)
discard ready.retire(ptr, destroy)
```

### Sharing Handles

```nim
# WRONG - sharing handle between threads
var sharedHandle: ThreadHandle[64]

proc thread1() {.thread.} =
  sharedHandle = registerThread(addr manager)  # BAD!

# RIGHT - each thread has own handle
proc thread1() {.thread.} =
  let handle = registerThread(addr manager)  # GOOD!
```

## Performance Tips

1. **Batch operations**: Pin once for multiple operations
2. **Amortize reclamation**: Reclaim every N operations
3. **Dedicated reclaimer**: Use background thread for reclamation
4. **Minimize pinning**: Only pin when accessing shared data
5. **Avoid blocking**: Don't block while pinned

## Next Steps

- Review [API reference](../api.md)
- Study complete examples in the repository
- Benchmark your integration
