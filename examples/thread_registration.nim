# examples/thread_registration.nim
## Thread registration lifecycle: multiple threads registering and using DEBRA.

import debra
import std/atomics

var manager: DebraManager[4]

proc workerThread() {.thread.} =
  # Register this thread with the manager
  let handle = registerThread(manager)

  # Perform some pin/unpin cycles
  for i in 0..<100:
    let u = unpinned(handle)
    let pinned = u.pin()

    # Simulate work in critical section
    discard

    let unpinResult = pinned.unpin()
    case unpinResult.kind:
    of uUnpinned:
      discard
    of uNeutralized:
      discard unpinResult.neutralized.acknowledge()

when isMainModule:
  # Initialize manager
  manager = initDebraManager[4]()
  setGlobalManager(addr manager)

  # Start worker threads
  var threads: array[4, Thread[void]]
  for i in 0..<4:
    createThread(threads[i], workerThread)

  # Wait for all threads to complete
  for i in 0..<4:
    joinThread(threads[i])

  echo "Thread registration example completed successfully"
