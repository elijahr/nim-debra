# examples/retire_single.nim
## Retiring a single object for safe reclamation.

import debra
import std/atomics

type Node = object
  value: int
  next: ptr Node

proc destroyNode(p: pointer) {.nimcall.} =
  echo "Destroying node with value: ", cast[ptr Node](p).value
  dealloc(p)

proc allocNode(value: int): ptr Node =
  result = cast[ptr Node](alloc0(sizeof(Node)))
  result.value = value

when isMainModule:
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)

  let handle = registerThread(manager)

  # Retire a single object
  block retireSingle:
    let u = unpinned(handle)
    let pinned = u.pin()

    # Simulate removing a node from a data structure
    let node = allocNode(42)
    echo "Allocated node with value: ", node.value

    # Retire the node - it will be reclaimed when safe
    let ready = retireReady(pinned)
    let retired = ready.retire(cast[pointer](node), destroyNode)
    echo "Node retired, waiting for safe reclamation"

    let unpinResult = pinned.unpin()
    case unpinResult.kind:
    of uUnpinned: discard
    of uNeutralized: discard unpinResult.neutralized.acknowledge()

  # Advance epochs to make reclamation possible
  manager.advance()
  manager.advance()
  manager.advance()

  # Reclaim
  let reclaimResult = reclaimStart(addr manager)
    .loadEpochs()
    .checkSafe()

  case reclaimResult.kind:
  of rReclaimReady:
    let count = reclaimResult.reclaimready.tryReclaim()
    echo "Reclaimed ", count, " object(s)"
  of rReclaimBlocked:
    echo "Reclamation blocked"

  echo "Retire single example completed successfully"
