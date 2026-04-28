# examples/retire_single.nim
## Single object retirement: the minimal pin -> retire -> unpin flow.
##
## Uses the `Atomic[ptr T]` lock-free pattern: `retain` to GC-pin a `ref` and
## hand back a raw pointer, `releaseDestructor[T]()` to balance the retain at
## reclamation time.

import debra

type
  NodeObj = object
    value: int

  Node = ref NodeObj

proc main() =
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)
  let handle = registerThread(manager)

  # Enter critical section
  let pinned = unpinned(handle).pin()

  # Retain a ref so it survives until DEBRA reclamation. `retain` returns a
  # raw `ptr NodeObj` suitable for atomic storage.
  let node = retain Node(value: 42)
  echo "Created node with value: ", node.value

  # Retire the node. The destructor (releaseDestructor) will GC_unref the
  # underlying ref once the epoch is safe.
  let ready = retireReady(pinned)
  discard ready.retire(cast[pointer](node), releaseDestructor[NodeObj]())
  echo "Node retired for later reclamation"

  # Exit critical section
  discard pinned.unpin()

  echo "Single retirement example completed"

when isMainModule:
  main()
