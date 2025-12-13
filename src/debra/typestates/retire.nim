## Retire typestate for adding objects to limbo bags.
##
## Must be pinned to retire objects.

import typestates

import ../types
import ../limbo
import ../managed
import ./guard

type
  RetireContext*[MaxThreads: static int] = object of RootObj
    handle*: ThreadHandle[MaxThreads]
    epoch*: uint64

  RetireReady*[MaxThreads: static int] = distinct RetireContext[MaxThreads]
  Retired*[MaxThreads: static int] = distinct RetireContext[MaxThreads]

typestate RetireContext[MaxThreads: static int]:
  inheritsFromRootObj = true
  states RetireReady[MaxThreads], Retired[MaxThreads]
  transitions:
    RetireReady[MaxThreads] -> Retired[MaxThreads]


proc retireReady*[MaxThreads: static int](
  p: Pinned[MaxThreads]
): RetireReady[MaxThreads] =
  ## Create retire context from pinned state.
  RetireReady[MaxThreads](RetireContext[MaxThreads](
    handle: p.handle,
    epoch: p.epoch
  ))


proc retireReadyFromRetired*[MaxThreads: static int](
  r: sink Retired[MaxThreads]
): RetireReady[MaxThreads] =
  ## Get back to RetireReady after retiring (for multiple retires).
  RetireReady[MaxThreads](RetireContext[MaxThreads](r))


proc retire*[MaxThreads: static int](
  r: sink RetireReady[MaxThreads],
  data: pointer,
  destructor: Destructor
): Retired[MaxThreads] {.transition.} =
  ## Retire an object. Will be reclaimed when safe.
  let ctx = RetireContext[MaxThreads](r)
  let state = addr ctx.handle.manager.threads[ctx.handle.idx]

  # Ensure we have a bag with space
  if state.currentBag == nil or state.currentBag.count >= LimboBagSize:
    let newBag = allocLimboBag()
    newBag.epoch = ctx.epoch
    newBag.next = state.currentBag
    if state.limboBagHead == nil:
      state.limboBagHead = newBag
    state.currentBag = newBag
    if state.limboBagTail == nil:
      state.limboBagTail = newBag

  # Add object to bag
  let bag = state.currentBag
  bag.objects[bag.count] = RetiredObject(data: data, destructor: destructor)
  inc bag.count

  Retired[MaxThreads](ctx)


proc retire*[T: ref, MaxThreads: static int](
  r: sink RetireReady[MaxThreads],
  obj: Managed[T]
): Retired[MaxThreads] {.transition.} =
  ## Retire a managed object for epoch-based reclamation.
  ##
  ## The object will be freed (via GC_unref) when its epoch
  ## becomes safe for reclamation.
  let ctx = RetireContext[MaxThreads](r)
  retire(RetireReady[MaxThreads](ctx), cast[pointer](obj.inner), unreffer[T]())


func handle*[MaxThreads: static int](r: RetireReady[MaxThreads]): ThreadHandle[MaxThreads] =
  RetireContext[MaxThreads](r).handle
