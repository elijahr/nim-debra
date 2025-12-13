# examples/lockfree_stack.nim
## Lock-free Treiber stack with DEBRA reclamation.

import debra
import std/[atomics, options]

type
  NodeObj[T] = object
    value: T
    next: Atomic[Managed[ref NodeObj[T]]]
  Node[T] = ref NodeObj[T]

  Stack*[T] = object
    head: Atomic[Managed[ref NodeObj[T]]]
    manager: ptr DebraManager[64]
    handle: ThreadHandle[64]

proc newStack*[T](manager: ptr DebraManager[64]): Stack[T] =
  result.manager = manager
  result.handle = registerThread(manager[])

proc push*[T](stack: var Stack[T], value: T) =
  let pinned = unpinned(stack.handle).pin()

  let newNode = managed Node[T](value: value)

  while true:
    var oldHead = stack.head.load(moAcquire)
    newNode.inner.next.store(oldHead, moRelaxed)
    if stack.head.compareExchange(oldHead, newNode, moRelease, moRelaxed):
      break

  discard pinned.unpin()

proc pop*[T](stack: var Stack[T]): Option[T] =
  let pinned = unpinned(stack.handle).pin()

  while true:
    var oldHead = stack.head.load(moAcquire)
    if oldHead.isNil:
      discard pinned.unpin()
      return none(T)

    let next = oldHead.inner.next.load(moRelaxed)
    if stack.head.compareExchange(oldHead, next, moRelease, moRelaxed):
      result = some(oldHead.value)

      # Retire the popped node
      let ready = retireReady(pinned)
      discard ready.retire(oldHead)

      discard pinned.unpin()
      return

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
  for _ in 0..3:
    manager.advance()

  let reclaimResult = reclaimStart(addr manager).loadEpochs().checkSafe()
  case reclaimResult.kind:
  of rReclaimReady:
    let count = reclaimResult.reclaimready.tryReclaim()
    echo "Reclaimed ", count, " nodes"
  of rReclaimBlocked:
    echo "Reclamation blocked"

  echo "Lock-free stack example completed"

when isMainModule:
  main()
