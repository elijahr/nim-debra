# examples/retire_multiple.nim
## Retiring multiple objects in a single critical section.

import debra
import std/atomics

type Node = object
  value: int

proc destroyNode(p: pointer) {.nimcall.} =
  dealloc(p)

proc allocNode(value: int): ptr Node =
  result = cast[ptr Node](alloc0(sizeof(Node)))
  result.value = value

when isMainModule:
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)

  let handle = registerThread(manager)

  # Retire multiple objects in one critical section
  block retireMultiple:
    let u = unpinned(handle)
    let pinned = u.pin()

    # Simulate batch removal from a data structure
    var ready = retireReady(pinned)
    for i in 0..<5:
      let node = allocNode(i * 10)
      let retired = ready.retire(cast[pointer](node), destroyNode)
      # Get ready state back for next retirement
      ready = retireReadyFromRetired(retired)
      echo "Retired node ", i

    let unpinResult = pinned.unpin()
    case unpinResult.kind:
    of uUnpinned: discard
    of uNeutralized: discard unpinResult.neutralized.acknowledge()

  # Advance epochs
  for _ in 0..<3:
    manager.advance()

  # Reclaim all
  let reclaimResult = reclaimStart(addr manager)
    .loadEpochs()
    .checkSafe()

  case reclaimResult.kind:
  of rReclaimReady:
    let count = reclaimResult.reclaimready.tryReclaim()
    echo "Reclaimed ", count, " objects"
  of rReclaimBlocked:
    echo "Reclamation blocked"

  echo "Retire multiple example completed successfully"
