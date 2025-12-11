# Reclamation

Understanding safe memory reclamation in DEBRA+.

## Overview

Reclamation is the process of safely freeing retired objects. The reclamation system walks thread-local limbo bags and frees objects from old epochs that are no longer accessible.

## Reclamation Steps

1. **Start**: Begin reclamation process
2. **Load epochs**: Read global epoch and all thread epochs
3. **Check safety**: Determine if any epochs are safe to reclaim
4. **Try reclaim**: Walk limbo bags and free eligible objects

## Epoch Safety

The safe epoch is the minimum of all pinned thread epochs. Objects retired in epoch E are safe to reclaim if `E < safeEpoch - 1`.

## Periodic Reclamation

Attempt reclamation every N operations to amortize the cost:

```nim
{% include-markdown "../../examples/reclamation_periodic.nim" %}
```

[:material-file-code: View full source](https://github.com/elijahr/nim-debra/blob/main/examples/reclamation_periodic.nim)

## Background Reclamation

Dedicate a thread to reclamation for best separation of concerns:

```nim
{% include-markdown "../../examples/reclamation_background.nim" %}
```

[:material-file-code: View full source](https://github.com/elijahr/nim-debra/blob/main/examples/reclamation_background.nim)

## Blocked Reclamation

If `safeEpoch <= 1`, reclamation is blocked. This is normal when:

- All threads pinned at current epoch
- Only one epoch has passed since start

Options when blocked:

1. **Advance epoch**: Trigger epoch advancement
2. **Wait**: Try again later
3. **Neutralize**: If a thread is stalled, neutralize it

## Reclamation Scheduling

**Too frequent:**
- Wastes CPU checking epochs
- Most checks find nothing to reclaim

**Too infrequent:**
- Accumulates memory
- Longer pause when reclaim happens

**Recommended**: Every 100-1000 operations or every 10-100ms.

## Performance Considerations

Reclamation cost:

- **Load epochs**: O(m) where m = max threads
- **Walk bags**: O(n) where n = retired objects
- **Total**: O(m + n)

Optimization tips:

1. **Batch reclamation**: Don't reclaim after every operation
2. **Separate thread**: Dedicate a thread to reclamation
3. **Threshold**: Only reclaim when enough objects accumulated

## Next Steps

- Learn about [neutralization](neutralization.md)
- Understand [integration patterns](integration.md)
