# examples/lockfree_stack.nim
## Complete lock-free stack implementation with DEBRA+ memory reclamation.

import debra
import std/[atomics, options]

type
  Node[T] = object
    value: T
    next: Atomic[ptr Node[T]]

  LockFreeStack*[T] = object
    top: Atomic[ptr Node[T]]
    manager: ptr DebraManager[64]
    handle: ThreadHandle[64]

proc destroyNode[T](p: pointer) {.nimcall.} =
  dealloc(p)

proc initStack*[T](manager: ptr DebraManager[64]): LockFreeStack[T] =
  result.top.store(nil, moRelaxed)
  result.manager = manager
  result.handle = registerThread(manager[])

proc push*[T](stack: var LockFreeStack[T], value: T) =
  let u = unpinned(stack.handle)
  let pinned = u.pin()

  let newNode = cast[ptr Node[T]](alloc0(sizeof(Node[T])))
  newNode.value = value

  var done = false
  while not done:
    var oldTop = stack.top.load(moAcquire)
    newNode.next.store(oldTop, moRelaxed)

    if stack.top.compareExchange(oldTop, newNode, moRelease, moRelaxed):
      done = true

  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

proc pop*[T](stack: var LockFreeStack[T]): Option[T] =
  let u = unpinned(stack.handle)
  let pinned = u.pin()

  var done = false
  result = none(T)

  while not done:
    var oldTop = stack.top.load(moAcquire)

    if oldTop == nil:
      done = true
    else:
      let next = oldTop.next.load(moRelaxed)

      if stack.top.compareExchange(oldTop, next, moRelease, moRelaxed):
        result = some(oldTop.value)

        # Retire old top for safe reclamation
        let ready = retireReady(pinned)
        discard ready.retire(cast[pointer](oldTop), destroyNode[T])

        done = true

  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

when isMainModule:
  var manager = initDebraManager[64]()
  setGlobalManager(addr manager)

  var stack = initStack[int](addr manager)

  # Push some values
  for i in 1..5:
    stack.push(i * 10)
    echo "Pushed: ", i * 10

  # Pop all values
  while true:
    let value = stack.pop()
    if value.isNone:
      break
    echo "Popped: ", value.get

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

  echo "Lock-free stack example completed successfully"
