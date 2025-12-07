# Neutralization

Understanding the signal-based neutralization protocol.

## Overview

Neutralization solves the stalled thread problem: what happens when a thread stays pinned for a long time? Without intervention, it blocks reclamation and memory accumulates unboundedly.

DEBRA+ uses POSIX signals to neutralize stalled threads, allowing epoch advancement and bounded memory.

## The Stalled Thread Problem

### Scenario

```
Thread 1: Pinned at epoch 100, doing long computation
Thread 2: Advanced to epoch 105
Thread 3: Advanced to epoch 105

Safe epoch = min(100, 105, 105) = 100
Objects retired at epoch < 99 can be freed

But Thread 1 is still at 100, blocking reclamation!
```

If Thread 1 stays pinned for minutes/hours:

- Reclamation is blocked indefinitely
- Memory accumulates in limbo bags
- System may run out of memory

## Signal-Based Neutralization

### How It Works

1. **Detection**: Reclamation detects thread pinned at old epoch
2. **Signal**: Send SIGUSR1 to stalled thread's OS process
3. **Handler**: Signal handler sets neutralization flag
4. **Check**: Thread checks flag when it unpins
5. **Acknowledge**: Thread acknowledges neutralization
6. **Advance**: Safe epoch can now advance past stalled thread

### Signal Handler Setup

The signal handler is installed during manager initialization:

```nim
proc neutralizationHandler(sig: cint) {.noconv.} =
  # Called when SIGUSR1 received
  # Set neutralization flag for this thread
  let tid = pthread_self()
  # ... find thread slot by OS thread ID ...
  manager.threads[idx].neutralized.store(true, moRelease)
```

## Neutralization Lifecycle

### 1. Detection Phase

During reclamation, check for stalled threads:

```nim
let globalEpoch = manager.globalEpoch.load(moAcquire)
let threshold = globalEpoch - 2  # Stalled if 2+ epochs behind

for i in 0..<MaxThreads:
  if manager.threads[i].pinned.load(moAcquire):
    let threadEpoch = manager.threads[i].epoch.load(moAcquire)
    if threadEpoch < threshold:
      # Thread i is stalled - neutralize it
      neutralizeThread(i)
```

### 2. Signal Delivery

Send SIGUSR1 to the stalled thread:

```nim
proc neutralizeThread(idx: int) =
  let osThreadId = manager.threads[idx].osThreadId.load(moAcquire)
  if osThreadId > 0:
    # Send signal to thread
    discard pthread_kill(osThreadId, QuiescentSignal)
```

### 3. Handler Execution

The signal handler runs asynchronously:

```nim
proc neutralizationHandler(sig: cint) {.noconv.} =
  # Running in context of stalled thread
  # Set flag to notify thread it was neutralized
  getCurrentThreadState().neutralized.store(true, moRelease)
```

### 4. Detection on Unpin

The thread checks the flag when it unpins:

```nim
let pinned = handle.pin()
# ... long computation ...
let result = pinned.unpin()  # Checks neutralization flag

if result.kind == uNeutralized:
  # We were neutralized during the computation
  echo "Thread was neutralized"
```

### 5. Acknowledgment

Before re-pinning, must acknowledge neutralization:

```nim
if result.kind == uNeutralized:
  let unpinned = result.neutralized.acknowledge()
  # Clears neutralization flag
  # Now can pin again
```

## Neutralization States

The typestate system enforces the protocol:

1. **Unpinned**: Normal state, can pin
2. **Pinned**: Critical section, might be neutralized
3. **Neutralized**: Was signaled, must acknowledge
4. **Unpinned**: After acknowledgment, can pin again

```nim
typestate EpochGuardContext:
  states Unpinned, Pinned, Neutralized
  transitions:
    Unpinned -> Pinned
    Pinned -> Unpinned | Neutralized as UnpinResult
    Neutralized -> Unpinned
```

## Handling Neutralization

### Automatic Handling

```nim
proc withPinnedSection[T](handle: ThreadHandle, op: proc(): T): T =
  var done = false
  while not done:
    let pinned = handle.pin()
    result = op()
    let unpinResult = pinned.unpin()

    case unpinResult.kind:
    of uUnpinned:
      done = true
    of uNeutralized:
      # Acknowledge and retry
      discard unpinResult.neutralized.acknowledge()
      # Loop will retry operation
```

### Manual Handling

```nim
let pinned = handle.pin()
# ... computation ...
let result = pinned.unpin()

if result.kind == uNeutralized:
  # We were interrupted - decide what to do
  echo "Operation was neutralized"

  # Acknowledge
  discard result.neutralized.acknowledge()

  # Retry or handle differently
  retryOperation()
```

## Neutralization Semantics

### What Neutralization Means

Neutralization is **advisory**, not forceful:

- Thread is **not** stopped mid-computation
- Thread is **not** killed or interrupted
- Thread **continues** running normally
- Flag is **checked** on next unpin

### Safety Guarantees

- Neutralization cannot corrupt memory
- Thread completes current operation safely
- Lock-free operations remain atomic
- Memory ordering is preserved

### Limitations

Neutralization cannot:

- Stop a thread in an infinite loop
- Interrupt blocking system calls
- Force a thread to check the flag
- Guarantee timely response

## Configuration

### Neutralization Threshold

How far behind before neutralizing?

```nim
const NeutralizationThreshold = 2  # Epochs

# Thread pinned at epoch 100
# Global epoch is 103
# Difference = 3 > threshold
# -> Neutralize
```

Lower threshold:

- More aggressive neutralization
- Better memory bounds
- More interruptions

Higher threshold:

- More lenient on long operations
- Higher memory usage
- Fewer interruptions

### Signal Choice

DEBRA+ uses SIGUSR1 by default:

```nim
const QuiescentSignal = SIGUSR1
```

Requirements:

- Must not be used by application
- Must not have default handler
- Must be available on platform

## Platform Considerations

### POSIX Systems

Neutralization works on:

- Linux
- macOS
- BSD variants
- Other POSIX-compliant systems

### Windows

Windows does not support pthread_kill. Alternatives:

- Use events/condition variables
- Polling-based checking
- Thread interruption APIs

Currently nim-debra targets POSIX only.

## Best Practices

### Keep Critical Sections Short

Avoid neutralization by keeping pin/unpin sections minimal:

```nim
# GOOD - short critical section
let pinned = handle.pin()
let node = queue.dequeue()
discard pinned.unpin()
processNode(node)

# BAD - long critical section
let pinned = handle.pin()
let node = queue.dequeue()
processNode(node)  # Long computation while pinned!
discard pinned.unpin()
```

### Handle Neutralization Gracefully

Don't treat neutralization as an error:

```nim
# GOOD - retry operation
let result = pinned.unpin()
if result.kind == uNeutralized:
  discard result.neutralized.acknowledge()
  retryOperation()

# BAD - abort on neutralization
let result = pinned.unpin()
if result.kind == uNeutralized:
  raise newException(ValueError, "Neutralized!")
```

### Monitor Neutralization Rate

Track how often neutralization occurs:

```nim
var neutralizationCount = 0

let result = pinned.unpin()
if result.kind == uNeutralized:
  inc neutralizationCount
  if neutralizationCount mod 100 == 0:
    echo "Warning: ", neutralizationCount, " neutralizations"
```

Frequent neutralization indicates:

- Critical sections are too long
- Operations are blocking
- Threshold is too aggressive

## Debugging Neutralization

### Detect Stalled Threads

```nim
proc findStalledThreads() =
  let globalEpoch = manager.globalEpoch.load(moAcquire)
  for i in 0..<MaxThreads:
    if manager.threads[i].pinned.load(moAcquire):
      let threadEpoch = manager.threads[i].epoch.load(moAcquire)
      let lag = globalEpoch - threadEpoch
      if lag > 2:
        echo "Thread ", i, " is stalled (lag=", lag, ")"
```

### Log Neutralization Events

```nim
proc neutralizationHandler(sig: cint) {.noconv.} =
  echo "Thread neutralized at ", epochClock()
  getCurrentThreadState().neutralized.store(true, moRelease)
```

## Next Steps

- Learn about [integration patterns](integration.md)
- Review [API reference](../api.md)
