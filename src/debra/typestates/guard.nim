# src/debra/typestates/guard.nim

## Epoch guard typestate (pin/unpin).
##
## Enforces correct pin/unpin lifecycle for critical sections:
## Unpinned -> Pinning -> Pinned -> (Unpinned | Neutralized)
##
## Key invariant: Thread must be pinned before accessing shared data.

import atomics

import ../types

type
  EpochUnpinned*[MaxThreads: static int] = object
    ## Thread is not in critical section. Safe for epoch advance.
    handle*: ThreadHandle[MaxThreads]

  EpochPinning*[MaxThreads: static int] = object
    ## Loading current epoch, about to enter critical section.
    handle*: ThreadHandle[MaxThreads]
    epoch*: uint64

  EpochPinned*[MaxThreads: static int] = object
    ## Thread is in critical section. Blocks reclamation of current epoch.
    handle*: ThreadHandle[MaxThreads]
    epoch*: uint64

  EpochNeutralized*[MaxThreads: static int] = object
    ## Thread was signaled and force-unpinned. Must acknowledge before re-pinning.
    handle*: ThreadHandle[MaxThreads]

  # Object variant for unpin result
  EpochUnpinResultKind* = enum
    uEpochUnpinned
    uEpochNeutralized

  EpochUnpinResult*[MaxThreads: static int] = object
    case kind*: EpochUnpinResultKind
    of uEpochUnpinned:
      epochunpinned*: EpochUnpinned[MaxThreads]
    of uEpochNeutralized:
      epochneutralized*: EpochNeutralized[MaxThreads]


proc start*[MaxThreads: static int](
  handle: ThreadHandle[MaxThreads]
): EpochUnpinned[MaxThreads] {.inline.} =
  ## Begin epoch guard lifecycle.
  EpochUnpinned[MaxThreads](handle: handle)


proc loadEpoch*[MaxThreads: static int](
  op: EpochUnpinned[MaxThreads]
): EpochPinning[MaxThreads] {.inline.} =
  ## Load current global epoch. First step of pinning.
  let epoch = op.handle.manager.globalEpoch.load(moAcquire)
  EpochPinning[MaxThreads](handle: op.handle, epoch: epoch)


proc pin*[MaxThreads: static int](
  op: EpochPinning[MaxThreads]
): EpochPinned[MaxThreads] {.inline.} =
  ## Enter critical section. Blocks reclamation of current epoch.
  let mgr = op.handle.manager
  let idx = op.handle.idx

  # Clear any previous neutralization flag
  mgr.threads[idx].neutralized.store(false, moRelease)

  # Store observed epoch
  mgr.threads[idx].epoch.store(op.epoch, moRelease)

  # Mark as pinned (MUST be last - makes us visible to reclaimer)
  mgr.threads[idx].pinned.store(true, moRelease)

  EpochPinned[MaxThreads](handle: op.handle, epoch: op.epoch)


proc unpin*[MaxThreads: static int](
  op: EpochPinned[MaxThreads]
): EpochUnpinResult[MaxThreads] {.inline.} =
  ## Leave critical section. Check if we were neutralized.
  let mgr = op.handle.manager
  let idx = op.handle.idx

  # Clear pinned flag
  mgr.threads[idx].pinned.store(false, moRelease)

  # Check if we were neutralized while pinned
  if mgr.threads[idx].neutralized.load(moAcquire):
    EpochUnpinResult[MaxThreads](
      kind: uEpochNeutralized,
      epochneutralized: EpochNeutralized[MaxThreads](handle: op.handle)
    )
  else:
    EpochUnpinResult[MaxThreads](
      kind: uEpochUnpinned,
      epochunpinned: EpochUnpinned[MaxThreads](handle: op.handle)
    )


proc acknowledge*[MaxThreads: static int](
  op: EpochNeutralized[MaxThreads]
): EpochUnpinned[MaxThreads] {.inline.} =
  ## Acknowledge neutralization. Required before re-pinning.
  let mgr = op.handle.manager
  let idx = op.handle.idx

  mgr.threads[idx].neutralized.store(false, moRelease)
  EpochUnpinned[MaxThreads](handle: op.handle)


# Convenience API

proc pin*[MaxThreads: static int](
  handle: ThreadHandle[MaxThreads]
): EpochPinned[MaxThreads] {.inline.} =
  ## Pin in one call (combines start -> loadEpoch -> pin).
  start(handle).loadEpoch().pin()
