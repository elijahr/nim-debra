# Epoch Advancement

Epoch-based reclamation only frees memory once the global epoch has advanced
past every retire's epoch. If nothing advances the global epoch, every retire
stamps the same epoch onto the limbo bag, `safeEpoch` never exceeds 1, and
reclamation is silently blocked. The limbo bag grows forever; reclaimers see
`ReclaimBlocked` on every pass.

`manager.advance()` increments the global epoch with one atomic `fetchAdd`.
Any registered thread may call it. The cost is one cache-line write that
contends across cores, so the question is not whether to advance but how
often.

## Cadence patterns

Three patterns cover almost every consumer:

**Per-retirement.** Call `manager.advance()` immediately after every
`retire`. Simplest model, highest atomic-store traffic. Pick this only when
retires are rare (one per request, one per allocation batch).

**Per-N retirements (recommended for hot paths).** Use
`handle.advanceEvery(n)` to amortize. The helper increments a non-atomic
per-handle counter and only performs the atomic store every `n`th call.
Typical `n` is 32 to 128 for queue-style hot paths. Larger `n` lets the
limbo bag grow more between advances; smaller `n` increases atomic-store
contention.

**Periodic-thread.** A dedicated background thread calls
`manager.advance()` plus `reclaimNow(manager)` on a timer (e.g. every
1 ms or every 1000 ops). Keeps the hot path free of any epoch work at the
cost of one extra registered thread.

## Worked example

A queue's pop hot path that retires a segment when its last slot drains:

```nim
proc pop(...): Option[T] =
  withPin(handle):
    # ... read slot, advance head ...
    if mySlot == LastSlot:
      it.retire(cast[pointer](seg), segmentDestructor)
  handle.advanceEvery(64)   # cadence-controlled global advance
  if eager:
    discard reclaimNow(manager)
```

`advanceEvery(64)` makes 63 of every 64 calls a single non-atomic
increment plus a branch; only call 64 pays the atomic `fetchAdd`.

## Pitfalls

- **Missing entirely.** Limbo bags grow unboundedly. `reclaimNow` always
  returns 0. The bug is silent until you measure RSS.
- **Too frequent.** Every retire calls `advance()`. The atomic store on
  `globalEpoch` ping-pongs the cache line between cores.
- **Too rare.** A 1ms timer thread is fine for most workloads, but if
  retires fire faster than the timer can advance, the limbo bag still
  grows. Pair a timer with a per-N helper for safety.

## See also

- [`withPin`](pin-unpin.md) - the pinned scope inside which retires happen.
- [`reclaimNow`](reclamation.md) - the reclamation pass that needs an
  advanced epoch to make progress.
- [`advance`](../api.md) - the underlying typestate transition.
