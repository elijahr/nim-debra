# examples/pin_unpin.nim
## Pin/unpin protocol: critical sections and neutralization handling.

import debra
import std/atomics

when isMainModule:
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)

  let handle = registerThread(manager)

  # Basic pin/unpin cycle
  block basicCycle:
    let u = unpinned(handle)
    let pinned = u.pin()

    # Access lock-free data structures here
    # All reads/writes to shared data should happen while pinned

    let unpinResult = pinned.unpin()
    case unpinResult.kind:
    of uUnpinned:
      echo "Normal unpin"
    of uNeutralized:
      echo "Was neutralized - acknowledging"
      discard unpinResult.neutralized.acknowledge()

  # Demonstrate neutralization handling
  block neutralizationDemo:
    let u = unpinned(handle)
    let pinned = u.pin()

    # Simulate being neutralized by setting the flag directly
    manager.threads[handle.idx].neutralized.store(true, moRelease)

    let unpinResult = pinned.unpin()
    case unpinResult.kind:
    of uUnpinned:
      echo "Normal unpin (unexpected)"
    of uNeutralized:
      echo "Detected neutralization - must acknowledge before re-pinning"
      let acknowledged = unpinResult.neutralized.acknowledge()
      # Now we can pin again
      let pinned2 = acknowledged.pin()
      discard pinned2.unpin()
      echo "Successfully re-pinned after acknowledgment"

  echo "Pin/unpin example completed successfully"
