# Reclamation

Understanding safe memory reclamation in DEBRA+.

## Overview

Reclamation is the process of safely freeing retired objects. The reclamation system walks thread-local limbo bags and frees objects from old epochs that are no longer accessible.

## Basic Reclamation

### Attempt Reclamation

```nim
let result = reclaimStart(addr manager)
  .loadEpochs()
  .checkSafe()

if result.kind == rReclaimReady:
  let count = result.reclaimready.tryReclaim()
  echo "Reclaimed ", count, " objects"
```

### Reclamation Steps

1. **Start**: Begin reclamation process
2. **Load epochs**: Read global epoch and all thread epochs
3. **Check safety**: Determine if any epochs are safe to reclaim
4. **Try reclaim**: Walk limbo bags and free eligible objects

## Epoch Safety

### Computing Safe Epoch

The safe epoch is the minimum of all pinned thread epochs:

```
Global Epoch: 100
Thread 1: pinned at 98
Thread 2: pinned at 100
Thread 3: unpinned
Thread 4: pinned at 99

Safe Epoch = min(98, 100, 99) = 98
```

### Reclamation Rule

Objects retired in epoch E are safe to reclaim if:

```
E < safeEpoch - 1
```

Why `-1`? Ensures at least one full epoch has passed since retirement.

## Reclamation Process

### Walking Limbo Bags

Reclamation walks bags from oldest (tail) to newest (head):

```
Scan direction: <----

currentBag --> [epoch=100, count=23] --> [epoch=99, count=64] --> [epoch=97, count=64]
                                                                   ^
                                                              limboBagTail
                                                              (oldest)
```

For each bag:

1. **Check epoch**: Is `bag.epoch < safeEpoch - 1`?
2. **If safe**: Call destructors, free bag, continue
3. **If not safe**: Stop scanning (newer bags are also not safe)

### Calling Destructors

For each object in a safe bag:

```nim
for i in 0..<bag.count:
  let obj = bag.objects[i]
  if obj.destructor != nil:
    obj.destructor(obj.data)
```

The destructor receives the original pointer and performs cleanup.

## Reclamation Scheduling

### When to Reclaim

Reclamation can happen:

1. **Periodically**: Background thread calls reclaim on a timer
2. **After operations**: Attempt reclaim after N retirements
3. **On memory pressure**: When memory usage exceeds threshold
4. **During idle**: When threads have no work

### Frequency Trade-offs

**Too frequent:**

- Wastes CPU checking epochs
- Interferes with real work
- Most checks find nothing to reclaim

**Too infrequent:**

- Accumulates memory
- Risk of OOM if threads stall
- Longer pause when reclaim happens

**Recommended**: Every 100-1000 operations or every 10-100ms.

## Reclamation Patterns

### Background Reclamation Thread

```nim
var shouldShutdown = false

proc reclaimThread() {.thread.} =
  while not shouldShutdown:
    let result = reclaimStart(addr manager)
      .loadEpochs()
      .checkSafe()

    if result.kind == rReclaimReady:
      discard result.reclaimready.tryReclaim()

    sleep(10)  # 10ms between attempts

var reclaimer: Thread[void]
createThread(reclaimer, reclaimThread)
```

### Periodic Reclamation

```nim
var opCount = 0

proc doOperation() =
  # ... perform lock-free operation ...

  inc opCount
  if opCount mod 100 == 0:
    # Every 100 operations
    let result = reclaimStart(addr manager)
      .loadEpochs()
      .checkSafe()
    if result.kind == rReclaimReady:
      discard result.reclaimready.tryReclaim()
```

### Threshold-Based Reclamation

```nim
proc retireWithReclaim(handle: ThreadHandle, ptr: pointer, destructor: Destructor) =
  let pinned = handle.pin()
  let ready = retireReady(pinned)
  discard ready.retire(ptr, destructor)
  discard pinned.unpin()

  # Count objects in limbo
  var total = 0
  var bag = manager.threads[handle.idx].limboBagHead
  while bag != nil:
    total += bag.count
    bag = bag.next

  # Reclaim if over threshold
  if total > 1000:
    let result = reclaimStart(addr manager)
      .loadEpochs()
      .checkSafe()
    if result.kind == rReclaimReady:
      discard result.reclaimready.tryReclaim()
```

## Blocked Reclamation

### When Reclamation Blocks

If `safeEpoch <= 1`, reclamation is blocked:

```nim
let result = reclaimStart(addr manager)
  .loadEpochs()
  .checkSafe()

if result.kind == rReclaimBlocked:
  # No epochs are safe to reclaim yet
  # Either:
  # - All threads pinned at current epoch
  # - Only one epoch has passed since start
  discard
```

This is normal in the first few epochs after startup.

### Handling Blocked Reclamation

Options:

1. **Advance epoch**: Trigger epoch advancement to move forward
2. **Wait**: Try again later
3. **Neutralize**: If a thread is stalled, neutralize it

## Multi-Thread Reclamation

### Per-Thread Reclamation

Each thread can reclaim its own limbo bags:

```nim
# Each thread reclaims its own bags
proc workerThread(idx: int) =
  let handle = registerThread(addr manager)

  for i in 0..<10000:
    # ... operations ...

    if i mod 100 == 0:
      # Only scans this thread's bags
      let result = reclaimStart(addr manager)
        .loadEpochs()
        .checkSafe()
      if result.kind == rReclaimReady:
        discard result.reclaimready.tryReclaim()
```

`tryReclaim()` scans all thread slots, but only reclaims bags belonging to each thread.

### Global Reclamation

Alternatively, a single reclamation thread can reclaim for all threads:

```nim
proc globalReclaimer() {.thread.} =
  while not shutdown:
    let result = reclaimStart(addr manager)
      .loadEpochs()
      .checkSafe()

    if result.kind == rReclaimReady:
      # Reclaims bags from all threads
      discard result.reclaimready.tryReclaim()

    sleep(10)
```

This centralizes reclamation but adds contention.

## Performance Considerations

### Reclamation Cost

- **Load epochs**: O(m) where m = max threads
- **Walk bags**: O(n) where n = retired objects
- **Call destructors**: O(n)
- **Total**: O(m + n)

### Optimization Tips

1. **Batch reclamation**: Don't reclaim after every operation
2. **Amortize cost**: Spread over many operations
3. **Separate thread**: Dedicate a thread to reclamation
4. **Threshold**: Only reclaim when enough objects accumulated

### Memory vs CPU Trade-off

- **Frequent reclamation**: Lower memory, higher CPU
- **Infrequent reclamation**: Higher memory, lower CPU

Tune based on your workload.

## Debugging Reclamation

### Check Limbo Bag State

```nim
proc dumpLimboBags(handle: ThreadHandle) =
  echo "Thread ", handle.idx, " limbo bags:"
  var bag = manager.threads[handle.idx].limboBagHead
  var bagNum = 0
  while bag != nil:
    echo "  Bag ", bagNum, ": epoch=", bag.epoch, " count=", bag.count
    inc bagNum
    bag = bag.next
```

### Monitor Reclamation Rate

```nim
var totalReclaimed = 0
var attempts = 0

proc monitoredReclaim() =
  inc attempts
  let result = reclaimStart(addr manager)
    .loadEpochs()
    .checkSafe()

  if result.kind == rReclaimReady:
    let count = result.reclaimready.tryReclaim()
    totalReclaimed += count
    echo "Reclaimed ", count, " objects (", totalReclaimed, " total in ", attempts, " attempts)"
```

## Next Steps

- Learn about [neutralization](neutralization.md)
- Understand [integration patterns](integration.md)
