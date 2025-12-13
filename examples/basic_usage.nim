# examples/basic_usage.nim
## Basic DEBRA+ usage: initialize manager, register thread, pin/unpin, retire, reclaim.

import debra
import std/atomics

# Node type using ref object pattern for self-reference
type
  NodeObj = object
    value: int
    next: Atomic[Managed[ref NodeObj]]
  Node = ref NodeObj

# Helper to perform one pin/unpin cycle with retirement
proc doCycle(handle: ThreadHandle[4], manager: var DebraManager[4], value: int) =
  # Enter critical section
  let u = unpinned(handle)
  let pinned = u.pin()

  # Create a managed node (GC won't collect until retired)
  let node = managed Node(value: value)

  # Retire the node for later reclamation
  let ready = retireReady(pinned)
  discard ready.retire(node)

  # Exit critical section
  let unpinResult = pinned.unpin()

  # Handle neutralization if it occurred
  case unpinResult.kind:
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
  for i in 0..<10:
    doCycle(handle, manager, i)

    # Advance epoch periodically
    if i mod 3 == 0:
      manager.advance()

  # 4. Attempt reclamation
  let reclaimResult = reclaimStart(addr manager)
    .loadEpochs()
    .checkSafe()

  case reclaimResult.kind:
  of rReclaimReady:
    let count = reclaimResult.reclaimready.tryReclaim()
    echo "Reclaimed ", count, " objects"
  of rReclaimBlocked:
    echo "Reclamation blocked (normal at startup)"

  echo "Basic usage example completed successfully"

when isMainModule:
  main()
