# Neutralization

Understanding the signal-based neutralization protocol.

## Overview

Neutralization solves the stalled thread problem: what happens when a thread stays pinned for a long time? Without intervention, it blocks reclamation and memory accumulates unboundedly.

DEBRA+ uses POSIX signals to neutralize stalled threads, allowing epoch advancement and bounded memory.

## The Stalled Thread Problem

If a thread stays pinned at an old epoch:

- Reclamation is blocked indefinitely
- Memory accumulates in limbo bags
- System may run out of memory

## How Neutralization Works

1. **Detection**: Reclamation detects thread pinned at old epoch
2. **Signal**: Send SIGUSR1 to stalled thread
3. **Handler**: Signal handler sets neutralization flag
4. **Check**: Thread checks flag when it unpins
5. **Acknowledge**: Thread acknowledges neutralization
6. **Advance**: Safe epoch can now advance past stalled thread

## Neutralization Handling Example

```nim
{% include-markdown "../../examples/neutralization_handling.nim" %}
```

[:material-file-code: View full source](https://github.com/elijahr/nim-debra/blob/main/examples/neutralization_handling.nim)

## Neutralization Semantics

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

How far behind before neutralizing? Default is 2 epochs.

Lower threshold = more aggressive neutralization, better memory bounds, more interruptions.

Higher threshold = more lenient on long operations, higher memory usage, fewer interruptions.

### Signal Choice

DEBRA+ uses SIGUSR1 by default. Requirements:

- Must not be used by application
- Must not have default handler
- Must be available on platform

## Platform Considerations

Neutralization works on POSIX systems (Linux, macOS, BSD). Windows does not support pthread_kill and would require alternative approaches.

## Best Practices

### Keep Critical Sections Short

Avoid neutralization by keeping pin/unpin sections minimal:

```nim
# GOOD - short critical section
let pinned = handle.pin()
let node = queue.dequeue()
discard pinned.unpin()
processNode(node)  # Outside critical section

# BAD - long critical section
let pinned = handle.pin()
let node = queue.dequeue()
processNode(node)  # Inside critical section!
discard pinned.unpin()
```

### Handle Neutralization Gracefully

Don't treat neutralization as an error - retry the operation.

### Monitor Neutralization Rate

Frequent neutralization indicates:

- Critical sections are too long
- Operations are blocking
- Threshold is too aggressive

## Next Steps

- Learn about [integration patterns](integration.md)
- Review API reference
