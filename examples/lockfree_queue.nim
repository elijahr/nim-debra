# examples/lockfree_queue.nim
## Lock-free Michael-Scott queue with DEBRA reclamation.
##
## Atomic node slots use `ptr NodeObj[T]`, not `ref NodeObj[T]`:
## `Atomic[ref T]` falls back to spinlock-based atomics on arc/orc, which
## silently defeats lock-free guarantees. `retain` / `releaseDestructor`
## from `debra/refptr` bridge a Nim `ref` into a raw pointer with explicit
## GC tracking.

import debra
import debra/atomics
import std/options

type
  NodeObj[T] = object
    value: T
    next: Atomic[ptr NodeObj[T]]

  Node[T] = ref NodeObj[T]

  Queue*[T] = object
    head: Atomic[ptr NodeObj[T]]
    tail: Atomic[ptr NodeObj[T]]
    manager: ptr DebraManager[64]
    handle: ThreadHandle[64]

proc newQueue*[T](manager: ptr DebraManager[64]): Queue[T] =
  result.manager = manager
  result.handle = registerThread(manager[])

  # Create sentinel node. `retain` pins it in the GC and yields a ptr we
  # can store atomically. The sentinel is balanced by the retire path
  # the first time it gets dequeued.
  let sentinel = retain Node[T]()
  result.head.store(sentinel, moRelaxed)
  result.tail.store(sentinel, moRelaxed)

proc enqueue*[T](queue: var Queue[T], value: T) =
  let newNode = retain Node[T](value: value)

  queue.handle.withPin:
    while true:
      let tail = queue.tail.load(moAcquire)
      let next = tail.next.load(moAcquire)

      if next == nil:
        var expected: ptr NodeObj[T] = nil
        if tail.next.compareExchangeStrong(expected, newNode, moRelease, moRelaxed):
          # Best-effort "help" to swing the tail forward. A spurious weak
          # failure here is fine — another enqueue/dequeue will retry the
          # same swing on its next iteration. Weak avoids the LL/SC retry
          # loop on weakly-ordered architectures.
          var observedTail = tail
          discard
            queue.tail.compareExchangeWeak(observedTail, newNode, moRelease, moRelaxed)
          break
      else:
        # Help-along: another producer enqueued but hasn't yet swung the
        # tail. Weak CAS is sufficient — spurious failure is harmless;
        # the next iteration retries.
        var observedTail = tail
        discard queue.tail.compareExchangeWeak(observedTail, next, moRelease, moRelaxed)

proc dequeue*[T](queue: var Queue[T]): Option[T] =
  result = none(T)

  queue.handle.withPin:
    block dequeueLoop:
      while true:
        let head = queue.head.load(moAcquire)
        let tail = queue.tail.load(moAcquire)
        let next = head.next.load(moAcquire)

        if head == tail:
          if next == nil:
            break dequeueLoop
          # Help-along: same as in `enqueue`'s help branch. Weak is fine
          # because a spurious failure is recovered by the next iteration.
          var observedTail = tail
          discard
            queue.tail.compareExchangeWeak(observedTail, next, moRelease, moRelaxed)
        else:
          let value = next.value
          var observedHead = head
          if queue.head.compareExchangeStrong(observedHead, next, moRelease, moRelaxed):
            # Retire old head (sentinel). The destructor will GC_unref it
            # once the epoch is safe, balancing the `retain` from newQueue
            # or the previous enqueue.
            it.retire(cast[pointer](head), releaseDestructor[NodeObj[T]]())
            result = some(value)
            break dequeueLoop

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
  for _ in 0 .. 3:
    manager.advance()

  let reclaimResult = reclaimStart(addr manager).loadEpochs().checkSafe()
  case reclaimResult.kind
  of rReclaimReady:
    let count = reclaimResult.reclaimready.tryReclaim()
    echo "Reclaimed ", count, " nodes"
  of rReclaimBlocked:
    echo "Reclamation blocked"

  echo "Lock-free queue example completed"

when isMainModule:
  main()
