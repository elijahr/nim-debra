# examples/lockfree_queue.nim
## Complete lock-free queue (Michael-Scott) with DEBRA+ memory reclamation.

import debra
import std/[atomics, options]

type
  QueueNode[T] = object
    value: T
    next: Atomic[ptr QueueNode[T]]

  LockFreeQueue*[T] = object
    head: Atomic[ptr QueueNode[T]]
    tail: Atomic[ptr QueueNode[T]]
    manager: ptr DebraManager[64]
    handle: ThreadHandle[64]

proc destroyQueueNode[T](p: pointer) {.nimcall.} =
  dealloc(p)

proc initQueue*[T](manager: ptr DebraManager[64]): LockFreeQueue[T] =
  # Create sentinel node
  let sentinel = cast[ptr QueueNode[T]](alloc0(sizeof(QueueNode[T])))
  sentinel.next.store(nil, moRelaxed)

  result.head.store(sentinel, moRelaxed)
  result.tail.store(sentinel, moRelaxed)
  result.manager = manager
  result.handle = registerThread(manager[])

proc enqueue*[T](queue: var LockFreeQueue[T], value: T) =
  let u = unpinned(queue.handle)
  let pinned = u.pin()

  let newNode = cast[ptr QueueNode[T]](alloc0(sizeof(QueueNode[T])))
  newNode.value = value
  newNode.next.store(nil, moRelaxed)

  var done = false
  while not done:
    var tail = queue.tail.load(moAcquire)
    var next = tail.next.load(moAcquire)

    if next == nil:
      var expected: ptr QueueNode[T] = nil
      if tail.next.compareExchange(expected, newNode, moRelease, moRelaxed):
        discard queue.tail.compareExchange(tail, newNode, moRelease, moRelaxed)
        done = true
    else:
      discard queue.tail.compareExchange(tail, next, moRelease, moRelaxed)

  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

proc dequeue*[T](queue: var LockFreeQueue[T]): Option[T] =
  let u = unpinned(queue.handle)
  let pinned = u.pin()

  var done = false
  result = none(T)

  while not done:
    var head = queue.head.load(moAcquire)
    var tail = queue.tail.load(moAcquire)
    let next = head.next.load(moAcquire)

    if next != nil:
      if head == tail:
        # Tail is lagging, help advance it
        discard queue.tail.compareExchange(tail, next, moRelease, moRelaxed)
      else:
        if queue.head.compareExchange(head, next, moRelease, moRelaxed):
          result = some(next.value)

          # Retire old head (sentinel) for safe reclamation
          let ready = retireReady(pinned)
          discard ready.retire(cast[pointer](head), destroyQueueNode[T])

          done = true
    else:
      done = true  # Queue is empty

  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

when isMainModule:
  var manager = initDebraManager[64]()
  setGlobalManager(addr manager)

  var queue = initQueue[int](addr manager)

  # Enqueue some values
  for i in 1..5:
    queue.enqueue(i * 10)
    echo "Enqueued: ", i * 10

  # Dequeue all values
  while true:
    let value = queue.dequeue()
    if value.isNone:
      break
    echo "Dequeued: ", value.get

  # Advance and reclaim
  for _ in 0..3:
    manager.advance()

  let reclaimResult = reclaimStart(addr manager)
    .loadEpochs()
    .checkSafe()

  case reclaimResult.kind:
  of rReclaimReady:
    let count = reclaimResult.reclaimready.tryReclaim()
    echo "Reclaimed ", count, " nodes"
  of rReclaimBlocked:
    echo "Reclamation blocked"

  echo "Lock-free queue example completed successfully"
