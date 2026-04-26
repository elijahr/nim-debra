## Reclaim typestate for safe memory reclamation.
##
## Walks the calling thread's limbo bags and reclaims objects retired before
## `safeEpoch`. Each thread reclaims only its own retired objects; cross-thread
## reclamation is not supported because the limbo bag list is mutated by the
## owning thread (via `retire`) without synchronization.
##
## ## Per-thread reclamation
##
## `tryReclaim` walks the calling thread's slot only. The slot is identified by
## the `ThreadHandle` passed to `reclaimStart(handle)`, or by the thread-local
## `threadLocalIdx` set during `registerThread` for the legacy
## `reclaimStart(addr manager)` form.
##
## A thread that retires but never calls `tryReclaim` will accumulate limbo
## bags that no other thread can reclaim on its behalf. If such a thread stalls
## or exits without draining its bags, those objects are leaked. The
## `neutralizeStalled` mechanism handles stalled-but-still-running threads (by
## forcing them to unpin so the global epoch can advance); it does not free
## their retired objects.
##
## ## Pitfalls
##
## * The `ReclaimStart` -> `EpochsLoaded` -> `ReclaimReady`/`ReclaimBlocked`
##   chain must be honored. `ReclaimBlocked` means the global epoch has not
##   advanced far enough for any retired object to be safe; this is normal,
##   not an error. `manager.advance()` increments the global epoch.
## * Reclamation does not require pinning. The walker only inspects per-thread
##   epoch stamps. Calling reclaim from a worker that is currently `Pinned`
##   on the same manager is safe but will see its own thread as a constraint
##   on `safeEpoch`.
## * `tryReclaim` is `notATransition` because `ReclaimReady` is the terminal
##   state of the `ReclaimContext` typestate and the count return value is
##   what the caller cares about.
## * Calling `reclaimStart(addr manager)` from an unregistered thread is a
##   bug: `threadLocalIdx` defaults to 0, so the call would silently walk
##   slot 0's bag list and race with that slot's owner. Prefer the handle
##   form `reclaimStart(handle)` whenever possible.
##
## ## See also
##
## * `debra/convenience.reclaimNow`_ - the one-shot wrapper.
## * `debra/typestates/retire`_ - puts objects into limbo bags.

import ../atomics
import typestates

import ../types
import ../limbo
import ../signal

type
  ReclaimContext*[MaxThreads: static int] = object of RootObj
    manager*: ptr DebraManager[MaxThreads]
    idx*: int ## Slot index of the calling thread; bag walk targets this slot only.
    globalEpoch*: uint64
    safeEpoch*: uint64

  ReclaimStart*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]
  EpochsLoaded*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]
  ReclaimReady*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]
  ReclaimBlocked*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]

typestate ReclaimContext[MaxThreads: static int]:
  inheritsFromRootObj = true
  states ReclaimStart[MaxThreads],
    EpochsLoaded[MaxThreads], ReclaimReady[MaxThreads], ReclaimBlocked[MaxThreads]
  transitions:
    ReclaimStart[MaxThreads] -> EpochsLoaded[MaxThreads]
    EpochsLoaded[MaxThreads] ->
      ReclaimReady[MaxThreads] | ReclaimBlocked[MaxThreads] as ReclaimCheck[MaxThreads]

proc reclaimStart*[MaxThreads: static int](
    handle: ThreadHandle[MaxThreads]
): ReclaimStart[MaxThreads] =
  ## Begin reclamation attempt for the calling thread's own retired objects.
  ##
  ## `handle` identifies the slot whose limbo bag list will be walked. Pass the
  ## handle returned by `registerThread` from the same thread that retired the
  ## objects. Each thread reclaims its own bags; this is the only safe pattern
  ## without per-list synchronization.
  ##
  ## See also: `debra/convenience.reclaimNow`_ for the one-shot wrapper.
  ReclaimStart[MaxThreads](
    ReclaimContext[MaxThreads](
      manager: handle.manager, idx: handle.idx, globalEpoch: 0, safeEpoch: 0
    )
  )

proc reclaimStart*[MaxThreads: static int](
    mgr: ptr DebraManager[MaxThreads]
): ReclaimStart[MaxThreads] =
  ## Legacy entry point that infers the calling thread's slot from the
  ## thread-local `threadLocalIdx` set by `registerThread`. Prefer the
  ## `reclaimStart(handle)` overload.
  ##
  ## Calling this from a thread that has not been registered with `mgr` is a
  ## bug; it will silently walk slot 0's bag list.
  ##
  ## See also: `debra/convenience.reclaimNow`_ for the one-shot wrapper.
  ReclaimStart[MaxThreads](
    ReclaimContext[MaxThreads](
      manager: mgr, idx: threadLocalIdx, globalEpoch: 0, safeEpoch: 0
    )
  )

proc loadEpochs*[MaxThreads: static int](
    s: ReclaimStart[MaxThreads]
): EpochsLoaded[MaxThreads] {.transition.} =
  ## Load global epoch and compute minimum epoch across pinned threads.
  var ctx = ReclaimContext[MaxThreads](s)
  ctx.globalEpoch = ctx.manager.globalEpoch.load(moAcquire)
  ctx.safeEpoch = ctx.globalEpoch

  for i in 0 ..< MaxThreads:
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
  ## Reclaim eligible objects from the calling thread's own limbo bag list.
  ##
  ## Returns the count of objects reclaimed. Walks only `manager.threads[idx]`
  ## where `idx` was captured into the `ReclaimContext` by `reclaimStart`.
  ## Other threads' bags are untouched: they reclaim their own.
  ##
  ## Cross-thread reclamation would race with the owner thread's `retire`
  ## mutations on `currentBag`, `limboBagHead`, and `limboBagTail`; those
  ## fields have no synchronization and are owned by the registered thread.
  runnableExamples:
    import debra
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let op = reclaimStart(handle).loadEpochs().checkSafe()
    case op.kind
    of rReclaimReady:
      discard op.reclaimready.tryReclaim()
    of rReclaimBlocked:
      # Brand-new manager: epoch hasn't advanced; this branch is normal.
      discard
  let ctx = ReclaimContext[MaxThreads](r)
  if ctx.idx < 0 or ctx.idx >= MaxThreads:
    # Caller is not a registered thread; nothing to reclaim from their slot.
    return 0
  let safeEpoch = ctx.safeEpoch - 1 # Objects retired BEFORE this epoch are safe
  var count = 0
  let state = addr ctx.manager.threads[ctx.idx]

  # Walk from tail (oldest) and reclaim eligible bags. Only the calling thread
  # mutates this list (via retire) and we are that thread, so no
  # synchronization is needed.
  var bag = state.limboBagTail
  var prevBag: ptr LimboBag = nil

  while bag != nil:
    if bag.epoch < safeEpoch:
      # This bag's objects are safe to reclaim
      for j in 0 ..< bag.count:
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
      if state.limboBagHead == bag:
        state.limboBagHead = nextBag

      freeLimboBag(bag)
      bag = nextBag
    else:
      # Not safe yet, stop walking
      break

  result = count
