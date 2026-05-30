# examples/unregister_thread.nim
## Register-work-unregister cycle, demonstrating slot reuse via
## `unregisterThread`.
##
## See `src/debra.nim:70-146` for the runtime API and the caller-obligation
## contract (thread-affine, idempotent, no in-flight pin, stale-handle
## aliasing undetected).

import debra

const MaxThreads = 2

var manager = initDebraManager[MaxThreads]()
setGlobalManager(addr manager)

# First registration: claims a slot.
let h1 = registerThread(manager)

# Do a pin/unpin cycle inside the slot.
block:
  var scope = pinScope(unpinned(h1))
  discard scope.consumed

# Release the slot. After this point, `h1` must not be reused.
unregisterThread(manager, h1)

# Second registration on the same thread reuses the freed slot.
let h2 = registerThread(manager)
doAssert h2.idx == h1.idx,
  "slot reuse: expected idx " & $h1.idx & ", got " & $h2.idx

# Release the second-cycle slot.
unregisterThread(manager, h2)

# Idempotent: a second unregister with the same (now stale) handle is a
# safe no-op (mask bit already clear).
unregisterThread(manager, h2)

echo "unregister_thread example completed successfully"
