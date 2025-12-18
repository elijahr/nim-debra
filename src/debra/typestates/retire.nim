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




proc retire*[T: ref, MaxThreads: static int](
  r: sink RetireReady[MaxThreads],
  obj: Managed[T]
): Retired[MaxThreads] {.transition.} =
  ## Retire a managed object for epoch-based reclamation.
  ##
  ## The object will be freed (via GC_unref) when its epoch
  ## becomes safe for reclamation.

  # Extract values we need before consuming r
  let handle = RetireContext[MaxThreads](r).handle
  let epoch = RetireContext[MaxThreads](r).epoch
  let state = addr handle.manager.threads[handle.idx]

  # Ensure we have a bag with space
  if state.currentBag == nil or state.currentBag.count >= LimboBagSize:
    let newBag = allocLimboBag()
    newBag.epoch = epoch
    newBag.next = state.currentBag
    if state.limboBagHead == nil:
      state.limboBagHead = newBag
    state.currentBag = newBag
    if state.limboBagTail == nil:
      state.limboBagTail = newBag

  # Add object to bag with type-specific unreffer
  let bag = state.currentBag
  bag.objects[bag.count] = RetiredObject(
    data: cast[pointer](obj.inner),
    destructor: unreffer[T]()
  )
  inc bag.count

  # Consume r to create result
  Retired[MaxThreads](RetireContext[MaxThreads](r))


proc retire*[MaxThreads: static int](
  r: sink RetireReady[MaxThreads],
  p: pointer,
  destructor: Destructor
): Retired[MaxThreads] {.transition.} =
  ## Retire a raw pointer for epoch-based reclamation.
  ##
  ## The destructor will be called when the epoch becomes safe.
  ## Use for manually-managed memory (ptr types, alloc/dealloc, etc.)

  # Extract values we need before consuming r
  let handle = RetireContext[MaxThreads](r).handle
  let epoch = RetireContext[MaxThreads](r).epoch
  let state = addr handle.manager.threads[handle.idx]

  # Ensure we have a bag with space
  if state.currentBag == nil or state.currentBag.count >= LimboBagSize:
    let newBag = allocLimboBag()
    newBag.epoch = epoch
    newBag.next = state.currentBag
    if state.limboBagHead == nil:
      state.limboBagHead = newBag
    state.currentBag = newBag
    if state.limboBagTail == nil:
      state.limboBagTail = newBag

  # Add object to bag with provided destructor
  let bag = state.currentBag
  bag.objects[bag.count] = RetiredObject(data: p, destructor: destructor)
  inc bag.count

  # Consume r to create result
  Retired[MaxThreads](RetireContext[MaxThreads](r))


func handle*[MaxThreads: static int](r: RetireReady[MaxThreads]): ThreadHandle[MaxThreads] =
  RetireContext[MaxThreads](r).handle
