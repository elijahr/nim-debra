# examples/pin_unpin.nim
## Pin/unpin lifecycle example with neutralization handling.

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

  # Basic pin/unpin cycle
  echo "=== Basic Pin/Unpin ==="
  block:
    let pinned = unpinned(handle).pin()
    echo "Thread pinned at epoch: ", pinned.epoch

    # Do work while pinned...
    let node = managed Node(value: 42)
    echo "Created node: ", node.value

    let unpinResult = pinned.unpin()
    case unpinResult.kind:
    of uUnpinned:
      echo "Normal unpin"
    of uNeutralized:
      echo "Was neutralized - acknowledging"
      discard unpinResult.neutralized.acknowledge()

  # Multiple pin/unpin cycles
  echo ""
  echo "=== Multiple Cycles ==="
  for i in 1..3:
    let pinned = unpinned(handle).pin()
    echo "Cycle ", i, ": pinned at epoch ", pinned.epoch

    # Retire a node
    let node = managed Node(value: i * 100)
    let ready = retireReady(pinned)
    discard ready.retire(node)

    let unpinResult = pinned.unpin()
    case unpinResult.kind:
    of uUnpinned:
      echo "Cycle ", i, ": unpinned normally"
    of uNeutralized:
      echo "Cycle ", i, ": neutralized"
      discard unpinResult.neutralized.acknowledge()

    # Advance epoch between cycles
    manager.advance()

  echo ""
  echo "Pin/unpin example completed"

when isMainModule:
  main()
