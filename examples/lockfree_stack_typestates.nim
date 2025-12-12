# examples/lockfree_stack_typestates.nim
## Lock-free stack with full typestate composition.
##
## Demonstrates:
## 1. Stack states (Empty, NonEmpty) enforced at compile time
## 2. DEBRA's pin/unpin/retire typestates used internally
## 3. Conceptual bridge from stack to item processing typestate
##
## This is a "correct by design" lock-free data structure.
##
## Note: Full bridge syntax (NonEmpty -> item_processing.Item.Unprocessed)
## requires module-qualified bridge support (see plan Tasks 1-5).
## For now, we demonstrate the composition by directly constructing
## Unprocessed items from popped values.

import typestates
import debra
import ./item_processing
import std/[atomics]

type
  Node[T] = object
    value: T
    next: Atomic[ptr Node[T]]

  StackBase[T] = object
    top: Atomic[ptr Node[T]]
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

proc destroyNode[T](p: pointer) {.nimcall.} =
  dealloc(p)

proc initStack*[T](manager: ptr DebraManager[64]): Empty[T] =
  ## Create a new empty stack.
  var base: StackBase[T]
  base.top.store(nil, moRelaxed)
  base.manager = manager
  base.handle = registerThread(manager[])
  Empty[T](base)

proc push*[T](stack: Empty[T], value: T): NonEmpty[T] {.transition.} =
  ## Push onto empty stack, returns NonEmpty.
  var base = StackBase[T](stack)

  # Enter DEBRA critical section
  let pinned = unpinned(base.handle).pin()

  let newNode = cast[ptr Node[T]](alloc0(sizeof(Node[T])))
  newNode.value = value
  newNode.next.store(nil, moRelaxed)
  base.top.store(newNode, moRelease)

  # Exit critical section
  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

  NonEmpty[T](base)

proc push*[T](stack: NonEmpty[T], value: T): NonEmpty[T] {.transition.} =
  ## Push onto non-empty stack, returns NonEmpty.
  var base = StackBase[T](stack)

  # Enter DEBRA critical section
  let pinned = unpinned(base.handle).pin()

  let newNode = cast[ptr Node[T]](alloc0(sizeof(Node[T])))
  newNode.value = value

  var done = false
  while not done:
    var oldTop = base.top.load(moAcquire)
    newNode.next.store(oldTop, moRelaxed)
    if base.top.compareExchange(oldTop, newNode, moRelease, moRelaxed):
      done = true

  # Exit critical section
  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

  NonEmpty[T](base)

proc pop*[T](stack: NonEmpty[T]): (PopResult[T], Unprocessed[T]) =
  ## Pop from non-empty stack.
  ## Returns (new stack state, item in Unprocessed state).
  ##
  ## The item is bridged to the item_processing typestate,
  ## ready to flow through Processing -> Completed|Failed.
  var base = StackBase[T](stack)

  # Enter DEBRA critical section - typestate enforced
  let pinned = unpinned(base.handle).pin()

  var resultStack: PopResult[T]
  var item: Unprocessed[T]

  block popLoop:
    while true:
      var oldTop = base.top.load(moAcquire)

      if oldTop == nil:
        # Stack is now empty
        resultStack = PopResult[T](kind: pEmpty, empty: Empty[T](base))
        # Create dummy item (won't be used in practice)
        item = Unprocessed[T](Item[T](value: default(T)))
        break popLoop

      let next = oldTop.next.load(moRelaxed)

      if base.top.compareExchange(oldTop, next, moRelease, moRelaxed):
        # Bridge: create item in Unprocessed state
        item = Unprocessed[T](Item[T](value: oldTop.value))

        # Retire the node through DEBRA - typestate enforced
        let ready = retireReady(pinned)
        discard ready.retire(cast[pointer](oldTop), destroyNode[T])

        # Determine new stack state
        if next == nil:
          resultStack = PopResult[T](kind: pEmpty, empty: Empty[T](base))
        else:
          resultStack = PopResult[T](kind: pNonempty, nonempty: NonEmpty[T](base))
        break popLoop

  # Exit DEBRA critical section - must handle neutralization
  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

  (resultStack, item)

when isMainModule:
  echo "Lock-Free Stack with Typestate Composition"
  echo "==========================================="
  echo ""

  # Initialize DEBRA manager
  var manager = initDebraManager[64]()
  setGlobalManager(addr manager)

  # Create empty stack - typestate: Empty[int]
  var stack = initStack[int](addr manager)
  echo "Created empty stack"

  # Push first element - typestate transitions: Empty -> NonEmpty
  var nonEmptyStack = stack.push(10)
  echo "Pushed 10 (stack is now NonEmpty)"

  # Push more elements - typestate: NonEmpty -> NonEmpty
  nonEmptyStack = nonEmptyStack.push(20)
  nonEmptyStack = nonEmptyStack.push(30)
  echo "Pushed 20, 30"
  echo ""

  # Pop and process items
  echo "Popping and processing items:"
  var currentStack = nonEmptyStack

  while true:
    let (popResult, item) = currentStack.pop()

    # Item is in Unprocessed state - process it through the pipeline
    let processing = item.startProcessing()
    let processResult = processing.finish(success = true)

    case processResult.kind:
    of pCompleted:
      echo "  Popped and completed: ", Item[int](processResult.completed).value
    of pFailed:
      echo "  Popped but failed: ", Item[int](processResult.failed).value

    # Check stack state
    case popResult.kind:
    of pEmpty:
      echo "  Stack is now empty"
      break
    of pNonempty:
      currentStack = popResult.nonempty

  echo ""

  # Reclaim retired memory
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
    echo "Reclamation blocked (threads still active)"

  echo ""
  echo "Lock-free stack with typestate composition completed successfully"
