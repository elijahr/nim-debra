# Getting Started

This guide walks through setting up and using nim-debra in your lock-free data structures.

## Installation

Add nim-debra to your `.nimble` file:

```nim
requires "debra >= 0.1.0"
```

Or install globally:

```bash
nimble install debra
```

## Basic Usage

### 1. Initialize the Manager

Create a DEBRA manager once per process. The generic parameter specifies the maximum number of threads:

```nim
import debra

# Support up to 64 threads
var manager: DebraManager[64]
```

### 2. Initialize and Set Global Manager

```nim
# Initialize the manager
let ready = uninitializedManager(addr manager).initialize()

# Optional: set as global for convenience
setGlobalManager(ready.getManager())
```

### 3. Register Threads

Each thread must register before using DEBRA operations:

```nim
# In each thread:
let handle = registerThread(addr manager)
```

### 4. Pin/Unpin Critical Sections

Wrap lock-free data structure access in pin/unpin:

```nim
# Enter critical section
let pinned = handle.pin()

# Access your lock-free data structure here
let value = myQueue.dequeue()

# Exit critical section
discard pinned.unpin()
```

### 5. Retire Objects

When removing objects from your data structure, retire them for later reclamation:

```nim
proc nodeDestructor(p: pointer) {.nimcall.} =
  let node = cast[ptr Node](p)
  dealloc(node)

let pinned = handle.pin()
let node = myQueue.dequeue()
let ready = retireReady(pinned)
discard ready.retire(cast[pointer](node), nodeDestructor)
discard pinned.unpin()
```

### 6. Periodic Reclamation

Periodically attempt to reclaim retired objects:

```nim
# In a background thread or after operations:
let result = reclaimStart(addr manager)
  .loadEpochs()
  .checkSafe()

if result.kind == rReclaimReady:
  let count = result.reclaimready.tryReclaim()
  echo "Reclaimed ", count, " objects"
```

## Complete Example

```nim
import debra

# Node type for lock-free queue
type Node = object
  value: int
  next: ptr Node

proc destroyNode(p: pointer) {.nimcall.} =
  dealloc(p)

# Initialize manager
var manager: DebraManager[4]
discard uninitializedManager(addr manager).initialize()

# Thread function
proc workerThread() =
  # Register thread
  let handle = registerThread(addr manager)

  # Work loop
  for i in 0..<1000:
    # Critical section
    let pinned = handle.pin()

    # ... access lock-free data ...

    # Retire removed node
    if nodeToRemove != nil:
      let ready = retireReady(pinned)
      discard ready.retire(cast[pointer](nodeToRemove), destroyNode)

    discard pinned.unpin()

    # Periodic reclamation
    if i mod 100 == 0:
      let result = reclaimStart(addr manager)
        .loadEpochs()
        .checkSafe()
      if result.kind == rReclaimReady:
        discard result.reclaimready.tryReclaim()
```

## Next Steps

- Learn about [DEBRA+ concepts](concepts.md)
- Understand [thread registration](thread-registration.md)
- Deep dive into [retiring objects](retiring-objects.md)
