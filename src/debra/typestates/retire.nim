## Retire typestate for adding objects to limbo bags.
##
## Must be pinned to retire objects.
##
## ## Pitfalls
##
## * `retire` is sink-form: it consumes `RetireReady[MT]` and returns
##   `Retired[MT]`. To retire multiple objects in the same pinned epoch,
##   convert back with `retireReadyFromRetired`. The `var`-form wrappers in
##   `debra/convenience` (`retire`, `retireBatch`) handle this for you.
## * The pointer/destructor pair handed to `retire(p, dtor)` is captured
##   into the limbo bag immediately. The destructor closure must remain
##   valid until reclamation runs (`Destructor` is a `nimcall` proc, so a
##   top-level proc or `releaseDestructor[T]()` result is fine).
## * Retiring the same pointer twice from different threads (or the same
##   thread across multiple `pin` cycles) double-frees on reclamation.
##   The library does not deduplicate.
##
## ## See also
##
## * `debra/convenience.withPin`_ + `it.retire(...)` - the recommended path.
## * `debra/typestates/reclaim`_ - eventual reclamation after epoch safety.

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
  RetireReady[MaxThreads](RetireContext[MaxThreads](handle: p.handle, epoch: p.epoch))

proc retireReadyFromRetired*[MaxThreads: static int](
    r: sink Retired[MaxThreads]
): RetireReady[MaxThreads] =
  ## Get back to RetireReady after retiring (for multiple retires).
  RetireReady[MaxThreads](RetireContext[MaxThreads](r))

proc retire*[T: ref, MaxThreads: static int](
    r: sink RetireReady[MaxThreads], obj: Managed[T]
): Retired[MaxThreads] {.transition.} =
  ## Retire a managed object for epoch-based reclamation.
  ##
  ## The object will be freed (via GC_unref) when its epoch
  ## becomes safe for reclamation.
  runnableExamples("-d:allowSpinlockManagedRef"):
    import debra
    type Node = ref object
      value: int
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let pinned = unpinned(handle).pin()
    let n = managed Node(value: 1)
    let retired = retireReady(pinned).retire(n)
    let pinnedAgain = Pinned[4](EpochGuardContext[4](
      handle: RetireContext[4](retired).handle,
      epoch: RetireContext[4](retired).epoch))
    discard pinnedAgain.unpin()

  # Extract values we need before consuming r
  let handle = RetireContext[MaxThreads](r).handle
  let epoch = RetireContext[MaxThreads](r).epoch
  let state = addr handle.manager.threads[handle.idx]

  # Ensure we have a bag with space. The bag list is a singly-linked FIFO:
  # `limboBagTail` is the oldest unfreed bag, `currentBag` is the newest, and
  # `next` chains oldest -> newer -> newest. Reclamation walks from tail.
  if state.currentBag == nil or state.currentBag.count >= LimboBagSize:
    let newBag = allocLimboBag()
    newBag.epoch = epoch
    newBag.next = nil
    if state.currentBag != nil:
      state.currentBag.next = newBag
    state.currentBag = newBag
    if state.limboBagTail == nil:
      state.limboBagTail = newBag
    # `limboBagHead` is no longer used; reclaim walks from tail. Retained on
    # the type for now to keep the struct layout stable; do not read it.
    state.limboBagHead = newBag

  # Add object to bag with type-specific unreffer
  let bag = state.currentBag
  bag.objects[bag.count] =
    RetiredObject(data: cast[pointer](obj.inner), destructor: unreffer[T]())
  inc bag.count

  # Consume r to create result
  Retired[MaxThreads](RetireContext[MaxThreads](r))

proc retire*[MaxThreads: static int](
    r: sink RetireReady[MaxThreads], p: pointer, destructor: Destructor
): Retired[MaxThreads] {.transition.} =
  ## Retire a raw pointer for epoch-based reclamation.
  ##
  ## The destructor will be called when the epoch becomes safe.
  ## Use for manually-managed memory (ptr types, alloc/dealloc, etc.)
  runnableExamples:
    import debra
    proc dtor(p: pointer) {.nimcall.} = dealloc(p)
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let pinned = unpinned(handle).pin()
    let raw = alloc0(8)
    let retired = retireReady(pinned).retire(raw, dtor)
    let pinnedAgain = Pinned[4](EpochGuardContext[4](
      handle: RetireContext[4](retired).handle,
      epoch: RetireContext[4](retired).epoch))
    discard pinnedAgain.unpin()

  # Extract values we need before consuming r
  let handle = RetireContext[MaxThreads](r).handle
  let epoch = RetireContext[MaxThreads](r).epoch
  let state = addr handle.manager.threads[handle.idx]

  # Ensure we have a bag with space. The bag list is a singly-linked FIFO:
  # `limboBagTail` is the oldest unfreed bag, `currentBag` is the newest, and
  # `next` chains oldest -> newer -> newest. Reclamation walks from tail.
  if state.currentBag == nil or state.currentBag.count >= LimboBagSize:
    let newBag = allocLimboBag()
    newBag.epoch = epoch
    newBag.next = nil
    if state.currentBag != nil:
      state.currentBag.next = newBag
    state.currentBag = newBag
    if state.limboBagTail == nil:
      state.limboBagTail = newBag
    # `limboBagHead` is no longer used; reclaim walks from tail. Retained on
    # the type for now to keep the struct layout stable; do not read it.
    state.limboBagHead = newBag

  # Add object to bag with provided destructor
  let bag = state.currentBag
  bag.objects[bag.count] = RetiredObject(data: p, destructor: destructor)
  inc bag.count

  # Consume r to create result
  Retired[MaxThreads](RetireContext[MaxThreads](r))

func handle*[MaxThreads: static int](
    r: RetireReady[MaxThreads]
): ThreadHandle[MaxThreads] =
  RetireContext[MaxThreads](r).handle
