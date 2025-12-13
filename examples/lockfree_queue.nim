# examples/lockfree_queue.nim
## Lock-free Michael-Scott queue with DEBRA reclamation.

import debra
import std/[atomics, options]

type
  NodeObj[T] = object
    value: T
    next: Atomic[Managed[ref NodeObj[T]]]
  Node[T] = ref NodeObj[T]

  Queue*[T] = object
    head: Atomic[Managed[ref NodeObj[T]]]
    tail: Atomic[Managed[ref NodeObj[T]]]
    manager: ptr DebraManager[64]
    handle: ThreadHandle[64]

proc newQueue*[T](manager: ptr DebraManager[64]): Queue[T] =
  result.manager = manager
  result.handle = registerThread(manager[])

  # Create sentinel node
  let sentinel = managed Node[T]()
  result.head.store(sentinel, moRelaxed)
  result.tail.store(sentinel, moRelaxed)

proc enqueue*[T](queue: var Queue[T], value: T) =
  let pinned = unpinned(queue.handle).pin()

  let newNode = managed Node[T](value: value)

  while true:
    var tail = queue.tail.load(moAcquire)
    let next = tail.inner.next.load(moAcquire)

    if next.isNil:
      var expected: Managed[Node[T]]
      if tail.inner.next.compareExchange(expected, newNode, moRelease, moRelaxed):
        discard queue.tail.compareExchange(tail, newNode, moRelease, moRelaxed)
        break
    else:
      discard queue.tail.compareExchange(tail, next, moRelease, moRelaxed)

  discard pinned.unpin()

proc dequeue*[T](queue: var Queue[T]): Option[T] =
  let pinned = unpinned(queue.handle).pin()

  while true:
    var head = queue.head.load(moAcquire)
    var tail = queue.tail.load(moAcquire)
    let next = head.inner.next.load(moAcquire)

    if head == tail:
      if next.isNil:
        discard pinned.unpin()
        return none(T)
      discard queue.tail.compareExchange(tail, next, moRelease, moRelaxed)
    else:
      let value = next.value
      if queue.head.compareExchange(head, next, moRelease, moRelaxed):
        # Retire old head (sentinel)
        let ready = retireReady(pinned)
        discard ready.retire(head)

        discard pinned.unpin()
        return some(value)

proc main() =
  var manager = initDebraManager[64]()
  setGlobalManager(addr manager)

  var queue = newQueue[int](addr manager)

  echo "Enqueueing 1, 2, 3..."
  queue.enqueue(1)
  queue.enqueue(2)
  queue.enqueue(3)

  echo "Dequeueing..."
  while true:
    let item = queue.dequeue()
    if item.isNone:
      break
    echo "  Dequeued: ", item.get

  # Reclaim
  for _ in 0..3:
    manager.advance()

  let reclaimResult = reclaimStart(addr manager).loadEpochs().checkSafe()
  case reclaimResult.kind:
  of rReclaimReady:
    let count = reclaimResult.reclaimready.tryReclaim()
    echo "Reclaimed ", count, " nodes"
  of rReclaimBlocked:
    echo "Reclamation blocked"

  echo "Lock-free queue example completed"

when isMainModule:
  main()
