# examples/basic_usage.nim
## Basic DEBRA+ usage: initialize manager, register thread, pin/unpin, retire, reclaim.

import debra
import std/atomics

# Simple node type for demonstration
type Node = object
  value: int
  next: ptr Node

# Destructor for retired nodes
proc destroyNode(p: pointer) {.nimcall.} =
  dealloc(p)

# Allocate a node
proc allocNode(value: int): ptr Node =
  result = cast[ptr Node](alloc0(sizeof(Node)))
  result.value = value

# Helper to perform one pin/unpin cycle with retirement
proc doCycle(handle: ThreadHandle[4], manager: var DebraManager[4], value: int) =
  # Enter critical section
  let u = unpinned(handle)
  let pinned = u.pin()

  # Allocate and immediately retire a node (simulating removal from data structure)
  let node = allocNode(value)

  # Retire the node for later reclamation
  let ready = retireReady(pinned)
  discard ready.retire(cast[pointer](node), destroyNode)

  # Exit critical section
  let unpinResult = pinned.unpin()

  # Handle neutralization if it occurred
  case unpinResult.kind:
  of uUnpinned:
    discard
  of uNeutralized:
    discard unpinResult.neutralized.acknowledge()

when isMainModule:
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
