# examples/neutralization_handling.nim
## Neutralization: handling signal-based interruption of stalled threads.

import debra
import std/atomics

when isMainModule:
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)

  let handle = registerThread(manager)

  # Wrapper that handles neutralization automatically
  proc withPinnedSection(body: proc()) =
    let u = unpinned(handle)
    let pinned = u.pin()

    body()

    let unpinResult = pinned.unpin()
    case unpinResult.kind:
    of uUnpinned:
      discard
    of uNeutralized:
      # Acknowledge and the caller can retry if needed
      discard unpinResult.neutralized.acknowledge()

  # Use the wrapper for clean critical sections
  withPinnedSection(proc() =
    echo "Working in critical section..."
  )

  # Manual handling with retry logic
  block manualRetry:
    var attempts = 0
    var done = false

    while not done and attempts < 3:
      inc attempts
      let u = unpinned(handle)
      let pinned = u.pin()

      # Simulate work
      echo "Attempt ", attempts

      # Simulate neutralization on first attempt
      if attempts == 1:
        manager.threads[handle.idx].neutralized.store(true, moRelease)

      let unpinResult = pinned.unpin()
      case unpinResult.kind:
      of uUnpinned:
        done = true
        echo "Completed on attempt ", attempts
      of uNeutralized:
        echo "Neutralized on attempt ", attempts, " - will retry"
        discard unpinResult.neutralized.acknowledge()

  echo "Neutralization handling example completed successfully"
