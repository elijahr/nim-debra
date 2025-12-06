# src/debra/typestates/reclaim.nim

## Reclamation typestate.
##
## Enforces correct sequencing for safe memory reclamation:
## Start -> LoadEpochs -> (Ready | Blocked)
##
## Key invariant: Only reclaim objects retired before safeEpoch.

import atomics

import ../types

type
  ReclaimStart*[MaxThreads: static int] = object
    ## Begin reclamation attempt.

  ReclaimEpochsLoaded*[MaxThreads: static int] = object
    ## Loaded global epoch and computed safe epoch.
    globalEpoch*: uint64
    safeEpoch*: uint64
      ## Minimum epoch across all pinned threads.

  ReclaimReady*[MaxThreads: static int] = object
    ## Ready to reclaim objects retired before safeEpoch.
    safeEpoch*: uint64

  ReclaimBlocked*[MaxThreads: static int] = object
    ## Cannot reclaim - no safe epoch exists.
    globalEpoch*: uint64

  # Object variant for check result
  ReclaimCheckKind* = enum
    cReclaimReady
    cReclaimBlocked

  ReclaimCheck*[MaxThreads: static int] = object
    case kind*: ReclaimCheckKind
    of cReclaimReady:
      reclaimready*: ReclaimReady[MaxThreads]
    of cReclaimBlocked:
      reclaimblocked*: ReclaimBlocked[MaxThreads]


proc reclaimStart*[MaxThreads: static int](): ReclaimStart[MaxThreads] {.inline.} =
  ## Begin reclamation attempt.
  ReclaimStart[MaxThreads]()


proc loadEpochs*[MaxThreads: static int](
  op: ReclaimStart[MaxThreads],
  manager: var DebraManager[MaxThreads]
): ReclaimEpochsLoaded[MaxThreads] {.inline.} =
  ## Load global epoch and compute minimum epoch across pinned threads.
  let globalEpoch = manager.globalEpoch.load(moAcquire)
  var minEpoch = globalEpoch

  for i in 0..<MaxThreads:
    if manager.threads[i].pinned.load(moAcquire):
      let threadEpoch = manager.threads[i].epoch.load(moAcquire)
      if threadEpoch < minEpoch:
        minEpoch = threadEpoch

  ReclaimEpochsLoaded[MaxThreads](globalEpoch: globalEpoch, safeEpoch: minEpoch)


proc checkSafe*[MaxThreads: static int](
  op: ReclaimEpochsLoaded[MaxThreads]
): ReclaimCheck[MaxThreads] {.inline.} =
  ## Check if any epochs are safe to reclaim.
  ## Safe to reclaim objects retired before (safeEpoch - 1).
  if op.safeEpoch > 1:
    ReclaimCheck[MaxThreads](
      kind: cReclaimReady,
      reclaimready: ReclaimReady[MaxThreads](safeEpoch: op.safeEpoch - 1)
    )
  else:
    ReclaimCheck[MaxThreads](
      kind: cReclaimBlocked,
      reclaimblocked: ReclaimBlocked[MaxThreads](globalEpoch: op.globalEpoch)
    )


proc canReclaim*[MaxThreads: static int](
  op: ReclaimReady[MaxThreads],
  retiredAtEpoch: uint64
): bool {.inline.} =
  ## Check if an object retired at given epoch can be reclaimed.
  retiredAtEpoch < op.safeEpoch
