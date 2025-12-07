## Reclaim typestate for safe memory reclamation.
##
## Walks limbo bags and reclaims objects retired before safeEpoch.

import atomics
import typestates

import ../types
import ../limbo

type
  ReclaimContext*[MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    globalEpoch*: uint64
    safeEpoch*: uint64

  ReclaimStart*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]
  EpochsLoaded*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]
  ReclaimReady*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]
  ReclaimBlocked*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]

typestate ReclaimContext[MaxThreads: static int]:
  states ReclaimStart[MaxThreads], EpochsLoaded[MaxThreads], ReclaimReady[MaxThreads], ReclaimBlocked[MaxThreads]
  transitions:
    ReclaimStart[MaxThreads] -> EpochsLoaded[MaxThreads]
    EpochsLoaded[MaxThreads] -> ReclaimReady[MaxThreads] | ReclaimBlocked[MaxThreads] as ReclaimCheck[MaxThreads]


proc reclaimStart*[MaxThreads: static int](
  mgr: ptr DebraManager[MaxThreads]
): ReclaimStart[MaxThreads] =
  ## Begin reclamation attempt.
  ReclaimStart[MaxThreads](ReclaimContext[MaxThreads](
    manager: mgr,
    globalEpoch: 0,
    safeEpoch: 0
  ))


proc loadEpochs*[MaxThreads: static int](
  s: ReclaimStart[MaxThreads]
): EpochsLoaded[MaxThreads] {.transition.} =
  ## Load global epoch and compute minimum epoch across pinned threads.
  var ctx = ReclaimContext[MaxThreads](s)
  ctx.globalEpoch = ctx.manager.globalEpoch.load(moAcquire)
  ctx.safeEpoch = ctx.globalEpoch

  for i in 0..<MaxThreads:
    if ctx.manager.threads[i].pinned.load(moAcquire):
      let threadEpoch = ctx.manager.threads[i].epoch.load(moAcquire)
      if threadEpoch < ctx.safeEpoch:
        ctx.safeEpoch = threadEpoch

  result = EpochsLoaded[MaxThreads](ctx)


func safeEpoch*[MaxThreads: static int](e: EpochsLoaded[MaxThreads]): uint64 =
  ReclaimContext[MaxThreads](e).safeEpoch


proc checkSafe*[MaxThreads: static int](
  e: EpochsLoaded[MaxThreads]
): ReclaimCheck[MaxThreads] {.transition.} =
  ## Check if any epochs are safe to reclaim.
  let ctx = ReclaimContext[MaxThreads](e)
  if ctx.safeEpoch > 1:
    ReclaimCheck[MaxThreads] -> ReclaimReady[MaxThreads](ctx)
  else:
    ReclaimCheck[MaxThreads] -> ReclaimBlocked[MaxThreads](ctx)


proc tryReclaim*[MaxThreads: static int](
  r: ReclaimReady[MaxThreads]
): int {.notATransition.} =
  ## Reclaim all eligible objects from all threads' limbo bags.
  ## Returns count of objects reclaimed.
  let ctx = ReclaimContext[MaxThreads](r)
  let safeEpoch = ctx.safeEpoch - 1  # Objects retired BEFORE this epoch are safe
  var count = 0

  for i in 0..<MaxThreads:
    let state = addr ctx.manager.threads[i]

    # Walk from tail (oldest) and reclaim eligible bags
    var bag = state.limboBagTail
    var prevBag: ptr LimboBag = nil

    while bag != nil:
      if bag.epoch < safeEpoch:
        # This bag's objects are safe to reclaim
        for j in 0..<bag.count:
          let obj = bag.objects[j]
          if obj.destructor != nil:
            obj.destructor(obj.data)
          inc count

        # Unlink and free bag
        let nextBag = bag.next
        if prevBag == nil:
          state.limboBagTail = nextBag
        else:
          prevBag.next = nextBag
        if state.currentBag == bag:
          state.currentBag = nextBag

        freeLimboBag(bag)
        bag = nextBag
      else:
        # Not safe yet, stop walking
        break

  result = count
