# examples/reclamation_periodic.nim
## Periodic reclamation: attempt reclamation every N operations.

import debra
import std/atomics

type
  NodeObj = object
    value: int
  Node = ref NodeObj

const ReclaimInterval = 10

proc doOperation(handle: ThreadHandle[64], i: int) =
  let u = unpinned(handle)
  let pinned = u.pin()

  let node = managed Node(value: i)
  let ready = retireReady(pinned)
  discard ready.retire(node)

  let unpinResult = pinned.unpin()
  case unpinResult.kind:
  of uUnpinned: discard
  of uNeutralized: discard unpinResult.neutralized.acknowledge()

proc periodicReclaimDemo() =
  var manager = initDebraManager[64]()
  setGlobalManager(addr manager)

  let handle = registerThread(manager)
  var totalReclaimed = 0

  # Perform operations with periodic reclamation
  for i in 0..<50:
    # Do one operation
    doOperation(handle, i)

    # Advance epoch periodically
    if i mod 5 == 0:
      manager.advance()

    # Attempt reclamation every ReclaimInterval operations
    if i mod ReclaimInterval == ReclaimInterval - 1:
      let reclaimResult = reclaimStart(addr manager)
        .loadEpochs()
        .checkSafe()

      case reclaimResult.kind:
      of rReclaimReady:
        let count = reclaimResult.reclaimready.tryReclaim()
        totalReclaimed += count
        echo "Operation ", i, ": reclaimed ", count, " objects"
      of rReclaimBlocked:
        echo "Operation ", i, ": reclamation blocked"

  echo "Total reclaimed: ", totalReclaimed, " objects"
  echo "Periodic reclamation example completed successfully"

when isMainModule:
  periodicReclaimDemo()
