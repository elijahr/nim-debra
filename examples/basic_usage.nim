# examples/basic_usage.nim
## Basic DEBRA+ usage: initialize manager, register thread, pin/retire/unpin,
## reclaim. Single-threaded, no atomic field — just the lifecycle.

import debra

type
  NodeObj = object
    value: int

  Node = ref NodeObj

# One pin/retire/unpin cycle.
proc doCycle(handle: ThreadHandle[4, ccSingle], value: int) =
  let u = unpinned(handle)
  let pinned = u.pin()

  # Retain the ref so it survives until DEBRA reclaims it. `retain` returns
  # a raw `ptr NodeObj`; the matching `releaseDestructor[NodeObj]()` runs
  # GC_unref at reclamation time.
  let node = retain Node(value: value)

  # Retire the node for later reclamation.
  let ready = retireReady(pinned)
  discard ready.retire(cast[pointer](node), releaseDestructor[NodeObj]())

  # Exit critical section. The unpin path may report a neutralization
  # (a stalled-thread escalation); acknowledge if so.
  let unpinResult = pinned.unpin()
  case unpinResult.kind
  of uUnpinned:
    discard
  of uNeutralized:
    discard unpinResult.neutralized.acknowledge()

proc main() =
  # 1. Initialize manager (supports up to 4 threads)
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)

  # 2. Register this thread
  let handle = registerThread(manager)

  # 3. Simulate some operations
  for i in 0 ..< 10:
    doCycle(handle, i)

    # Advance epoch periodically
    if i mod 3 == 0:
      manager.advance()

  # 4. Attempt reclamation
  let reclaimResult = reclaimStart(addr manager).loadEpochs().checkSafe()

  case reclaimResult.kind
  of rReclaimReady:
    let count = reclaimResult.reclaimready.tryReclaim()
    echo "Reclaimed ", count, " objects"
  of rReclaimBlocked:
    echo "Reclamation blocked (normal at startup)"

  echo "Basic usage example completed successfully"

when isMainModule:
  main()
