# examples/pin_unpin.nim
## Pin/unpin lifecycle example with neutralization handling.

import debra

type
  NodeObj = object
    value: int

  Node = ref NodeObj

proc main() =
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)
  let handle = registerThread(manager)

  # Basic pin/unpin cycle (no retire). The unpin result discriminates
  # between a normal unpin and a neutralization; the latter happens when
  # `neutralizeStalled` signaled this thread while it was pinned.
  echo "=== Basic Pin/Unpin ==="
  block:
    let pinned = unpinned(handle).pin()
    echo "Thread pinned at epoch: ", pinned.epoch

    let unpinResult = pinned.unpin()
    case unpinResult.kind
    of uUnpinned:
      echo "Normal unpin"
    of uNeutralized:
      echo "Was neutralized - acknowledging"
      discard unpinResult.neutralized.acknowledge()

  # Multiple pin/retire/unpin cycles using the high-level `withPin` sugar.
  # `withPin` injects `it: var RetireReady[MT]` and unpins on scope exit
  # (including raises). `retain` GC-pins the ref; `releaseDestructor` is
  # the matching destructor that runs at reclamation time.
  echo ""
  echo "=== Multiple Cycles (withPin) ==="
  let dtor = releaseDestructor[NodeObj]()
  for i in 1 .. 3:
    handle.withPin:
      echo "Cycle ", i, ": pinned"
      let node = retain Node(value: i * 100)
      it.retire(cast[pointer](node), dtor)

    # Advance epoch between cycles so reclamation can make progress.
    manager.advance()

  echo ""
  echo "Pin/unpin example completed"

when isMainModule:
  main()
