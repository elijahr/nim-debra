# examples/retire_multiple.nim
## Multiple object retirement example.

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

  # Retire multiple nodes in a single critical section
  var ready = retireReady(pinned)

  for i in 1..5:
    let node = managed Node(value: i * 10)
    echo "Retiring node with value: ", node.value
    let retired = ready.retire(node)
    ready = retireReadyFromRetired(retired)

  echo "Retired 5 nodes"

  # Exit critical section
  discard pinned.unpin()

  echo "Multiple retirement example completed"

when isMainModule:
  main()
