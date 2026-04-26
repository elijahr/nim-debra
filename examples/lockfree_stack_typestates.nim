# examples/lockfree_stack_typestates.nim
## Lock-free stack with full typestate composition.
##
## Demonstrates:
## 1. Stack states (Empty, NonEmpty) enforced at compile time
## 2. DEBRA's pin/unpin/retire typestates used internally
## 3. Manual bridge from stack to item processing typestate
##
## This is a "correct by design" lock-free data structure.
##
## ## Why `Atomic[ptr NodeObj[T]]` and not `Atomic[Managed[ref NodeObj[T]]]`
##
## `Managed[ref T]` is the right tool for non-atomic shared ownership.
## But `Atomic[ref T]` (and therefore `Atomic[Managed[ref T]]`) falls back
## to spinlock-based atomics on arc/orc, defeating lock-free guarantees.
##
## For atomic pointer storage in lock-free code, this example uses the
## explicit `retain` / `release` / `releaseDestructor` helpers from
## `debra/refptr`: `retain` increments the GC ref count and hands back a
## raw `ptr T`, `releaseDestructor[T]()` is a `Destructor` that DEBRA
## calls at reclamation time to balance the retain.

import typestates
import debra
import debra/atomics
import ./item_processing
import std/options

type
  NodeObj[T] = object
    value: T
    next: Atomic[ptr NodeObj[T]]
  Node[T] = ref NodeObj[T]

  StackBase[T] = object
    top: Atomic[ptr NodeObj[T]]
    manager: ptr DebraManager[64]
    handle: ThreadHandle[64]

  Empty*[T] = distinct StackBase[T]
    ## Stack with no elements.

  NonEmpty*[T] = distinct StackBase[T]
    ## Stack with at least one element.

typestate StackBase[T]:
  consumeOnTransition = false
  states Empty[T], NonEmpty[T]
  transitions:
    Empty[T] -> NonEmpty[T]
    NonEmpty[T] -> Empty[T] | NonEmpty[T] as PopResult[T]

proc initStack*[T](manager: ptr DebraManager[64]): Empty[T] =
  ## Create a new empty stack.
  var base: StackBase[T]
  base.manager = manager
  base.handle = registerThread(manager[])
  Empty[T](base)

proc push*[T](stack: Empty[T], value: T): NonEmpty[T] {.transition.} =
  ## Push onto empty stack, returns NonEmpty.
  var base = StackBase[T](stack)

  let pinned = unpinned(base.handle).pin()

  let newNode = retain Node[T](value: value)
  base.top.store(newNode, moRelease)

  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

  NonEmpty[T](base)

proc push*[T](stack: NonEmpty[T], value: T): NonEmpty[T] {.transition.} =
  ## Push onto non-empty stack, returns NonEmpty.
  var base = StackBase[T](stack)

  let pinned = unpinned(base.handle).pin()

  let newNode = retain Node[T](value: value)

  while true:
    let oldTop = base.top.load(moAcquire)
    newNode.next.store(oldTop, moRelaxed)
    var observed = oldTop
    if base.top.compareExchangeStrong(observed, newNode, moRelease, moRelaxed):
      break

  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

  NonEmpty[T](base)

proc pop*[T](stack: NonEmpty[T]): (PopResult[T], Option[Unprocessed[T]]) =
  ## Pop from non-empty stack.
  ## Returns (new stack state, optional item in Unprocessed state).
  var base = StackBase[T](stack)

  let pinned = unpinned(base.handle).pin()

  var resultStack: PopResult[T]
  var item: Option[Unprocessed[T]]

  block popLoop:
    while true:
      let oldTop = base.top.load(moAcquire)

      if oldTop == nil:
        resultStack = PopResult[T](kind: pEmpty, empty: Empty[T](base))
        item = none(Unprocessed[T])
        break popLoop

      let next = oldTop.next.load(moRelaxed)

      var observed = oldTop
      if base.top.compareExchangeStrong(observed, next, moRelease, moRelaxed):
        item = some(Unprocessed[T](Item[T](value: oldTop.value)))

        # Retire the node. The destructor balances the `retain` from
        # `push` once the epoch is safe.
        let ready = retireReady(pinned)
        discard ready.retire(
          cast[pointer](oldTop), releaseDestructor[NodeObj[T]]())

        if next == nil:
          resultStack = PopResult[T](kind: pEmpty, empty: Empty[T](base))
        else:
          resultStack = PopResult[T](kind: pNonempty, nonempty: NonEmpty[T](base))
        break popLoop

  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

  (resultStack, item)

when isMainModule:
  echo "Lock-Free Stack with Typestate Composition"
  echo "==========================================="
  echo ""

  var manager = initDebraManager[64]()
  setGlobalManager(addr manager)

  var stack = initStack[int](addr manager)
  echo "Created empty stack"

  var nonEmptyStack = stack.push(10)
  echo "Pushed 10 (stack is now NonEmpty)"

  nonEmptyStack = nonEmptyStack.push(20)
  nonEmptyStack = nonEmptyStack.push(30)
  echo "Pushed 20, 30"
  echo ""

  echo "Popping and processing items:"
  var currentStack = nonEmptyStack

  while true:
    let (popResult, itemOpt) = currentStack.pop()

    if itemOpt.isSome:
      let item = itemOpt.get
      let processing = item.startProcessing()
      let processResult = processing.finish(success = true)

      case processResult.kind:
      of pCompleted:
        echo "  Popped and completed: ", Item[int](processResult.completed).value
      of pFailed:
        echo "  Popped but failed: ", Item[int](processResult.failed).value
    else:
      echo "  Race condition: another thread popped the item first"

    case popResult.kind:
    of pEmpty:
      echo "  Stack is now empty"
      break
    of pNonempty:
      currentStack = popResult.nonempty

  echo ""

  for _ in 0..3:
    manager.advance()

  let reclaimResult = reclaimStart(addr manager).loadEpochs().checkSafe()

  case reclaimResult.kind:
  of rReclaimReady:
    let count = reclaimResult.reclaimready.tryReclaim()
    echo "Reclaimed ", count, " nodes"
  of rReclaimBlocked:
    echo "Reclamation blocked (threads still active)"

  echo ""
  echo "Lock-free stack with typestate composition completed successfully"
