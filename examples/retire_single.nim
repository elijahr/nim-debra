# examples/retire_single.nim
## Single object retirement example.

import debra
import std/atomics

type
  NodeObj = object
    value: int
    next: Atomic[Managed[ref NodeObj]]
  Node = ref NodeObj

proc main() =
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)
  let handle = registerThread(manager)

  # Enter critical section
  let pinned = unpinned(handle).pin()

  # Create a managed node
  let node = managed Node(value: 42)
  echo "Created node with value: ", node.value

  # Retire the node
  let ready = retireReady(pinned)
  discard ready.retire(node)
  echo "Node retired for later reclamation"

  # Exit critical section
  discard pinned.unpin()

  echo "Single retirement example completed"

when isMainModule:
  main()
