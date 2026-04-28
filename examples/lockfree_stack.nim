# examples/lockfree_stack.nim
## Lock-free Treiber stack with DEBRA reclamation.
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

  Stack*[T] = object
    head: Atomic[ptr NodeObj[T]]
    manager: ptr DebraManager[64]
    handle: ThreadHandle[64]

proc newStack*[T](manager: ptr DebraManager[64]): Stack[T] =
  result.manager = manager
  result.handle = registerThread(manager[])

proc push*[T](stack: var Stack[T], value: T) =
  let newNode = retain Node[T](value: value)

  stack.handle.withPin:
    while true:
      let oldHead = stack.head.load(moAcquire)
      newNode.next.store(oldHead, moRelaxed)
      var observed = oldHead
      if stack.head.compareExchangeStrong(observed, newNode, moRelease, moRelaxed):
        break

proc pop*[T](stack: var Stack[T]): Option[T] =
  result = none(T)

  stack.handle.withPin:
    block popLoop:
      while true:
        let oldHead = stack.head.load(moAcquire)
        if oldHead == nil:
          break popLoop

        let next = oldHead.next.load(moRelaxed)
        var observed = oldHead
        if stack.head.compareExchangeStrong(observed, next, moRelease, moRelaxed):
          result = some(oldHead.value)
          # Retire the popped node. The destructor balances the `retain`
          # done by `push` once the epoch is safe.
          it.retire(cast[pointer](oldHead), releaseDestructor[NodeObj[T]]())
          break popLoop

proc main() =
  var manager = initDebraManager[64]()
  setGlobalManager(addr manager)

  var stack = newStack[int](addr manager)

  echo "Pushing 1, 2, 3..."
  stack.push(1)
  stack.push(2)
  stack.push(3)

  echo "Popping..."
  while true:
    let item = stack.pop()
    if item.isNone:
      break
    echo "  Popped: ", item.get

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

  echo "Lock-free stack example completed"

when isMainModule:
  main()
