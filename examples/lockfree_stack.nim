# examples/lockfree_stack.nim
## Lock-free Treiber stack with DEBRA reclamation.
##
## ## Why `Atomic[ptr NodeObj[T]]` and not `Atomic[Managed[ref NodeObj[T]]]`
##
## `Managed[ref T]` is the right tool for non-atomic shared ownership: it
## keeps a ref alive across DEBRA epochs and integrates with Nim's GC.
## But `Atomic[ref T]` (and therefore `Atomic[Managed[ref T]]`) falls back
## to spinlock-based atomics on arc/orc, which silently defeats lock-free
## guarantees.
##
## For atomic pointer storage in lock-free code, this example uses the
## explicit `retain` / `release` / `releaseDestructor` helpers from
## `debra/refptr`: `retain` increments the GC ref count and hands back a
## raw `ptr T`, `releaseDestructor[T]()` is a `Destructor` that DEBRA
## calls at reclamation time to balance the retain.

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
