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

import ../atomics
import ../types
import ../limbo
import ./guard

type
  RetireContext*[MaxThreads: static int] = object of RootObj
    handle*: ThreadHandle[MaxThreads]
    epoch*: uint64

  RetireReady*[MaxThreads: static int] = distinct RetireContext[MaxThreads]
  Retired*[MaxThreads: static int] = distinct RetireContext[MaxThreads]

typestate RetireContext[MaxThreads: static int]:
  inheritsFromRootObj = true
  opaqueStates = true
  states RetireReady[MaxThreads], Retired[MaxThreads]
  initial:
    RetireReady[MaxThreads]
  terminal:
    Retired[MaxThreads]
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

proc pinnedFromRetired*[MaxThreads: static int](
    r: sink Retired[MaxThreads]
): Pinned[MaxThreads] =
  ## Return a `Pinned[MaxThreads]` reconstructed from a `Retired[MaxThreads]`
  ## value, allowing the caller to keep working in the same pinned epoch
  ## (e.g. interleaving reads with further retires) instead of unpinning
  ## immediately after a retire.
  ##
  ## Symmetric to `retireReadyFromRetired`: same underlying
  ## `RetireContext[MaxThreads]`, projected to the `Pinned` typestate via
  ## the `EpochGuardContext[MaxThreads]` shape (handle + epoch). The slot's
  ## `pinned` flag is unchanged; this is a typestate rebrand, not a
  ## re-pin.
  ##
  ## See also: `retireReadyFromRetired`_, `retire`_, `debra/typestates/guard.pin`_.
  runnableExamples:
    import debra
    proc dtor(p: pointer) {.nimcall.} =
      dealloc(p)

    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    # Stay in the pinned epoch across a retire so the thread can keep
    # reading shared state without unpinning and re-pinning.
    let pinned = unpinned(handle).pin()
    let ready = retireReady(pinned)
    let raw = alloc0(8)
    let retired = ready.retire(raw, dtor)
    let pinnedAgain = pinnedFromRetired(retired)
    discard pinnedAgain.unpin()

  let ctx = RetireContext[MaxThreads](r)
  Pinned[MaxThreads](
    EpochGuardContext[MaxThreads](handle: ctx.handle, epoch: ctx.epoch)
  )

proc retire*[MaxThreads: static int](
    r: sink RetireReady[MaxThreads], p: pointer, destructor: Destructor
): Retired[MaxThreads] {.transition.} =
  ## Retire a raw pointer for epoch-based reclamation.
  ##
  ## The destructor will be called when the epoch becomes safe.
  ## Use for manually-managed memory (ptr types, alloc/dealloc, etc.)
  runnableExamples:
    import debra
    proc dtor(p: pointer) {.nimcall.} =
      dealloc(p)

    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let pinned = unpinned(handle).pin()
    let raw = alloc0(8)
    let retired = retireReady(pinned).retire(raw, dtor)
    let pinnedAgain = pinnedFromRetired(retired)
    discard pinnedAgain.unpin()

  # Extract values we need before consuming r
  let handle = RetireContext[MaxThreads](r).handle
  let state = addr handle.manager.threads[handle.idx]

  # Record the CURRENT global epoch as the bag's epoch, not the pin's
  # captured epoch. This is the canonical DEBRA/EBR retire-time invariant.
  #
  # If we used the pin's captured epoch, a reader that pinned at a *later*
  # global epoch could still observe a not-yet-detached pointer (its load of
  # the protected variable happened before our detach CAS). When that
  # reader's pin is later checked by `loadEpochs`, its epoch would be
  # numerically larger than `bag.epoch`, so `bag.epoch < safeEpoch - 1`
  # could pass even though the reader is still actively reading the retired
  # object — a use-after-free.
  #
  # An SC RMW on a stack-local atomic participates in the C11 SC total
  # order S, pairing with the SC RMW in `pin` and the SC ops in
  # `loadEpochs`. The hardware StoreLoad barrier is per-CPU (`lock`-prefixed
  # RMW on x86, `ldaxr`/`stlxr` seq-cst pair on ARM), and S is a single
  # total order across every SC op regardless of which atomic location it
  # touches (C11 §29.3), so a stack-local atomic gives the same
  # synchronisation as an SC RMW on `globalEpoch` while avoiding the
  # cross-core cache-line bouncing of the shared global counter under
  # concurrent retire. The subsequent acquire load on `globalEpoch`
  # synchronises-with the latest `advance`-side release store, yielding a
  # value that dominates any earlier capture; `bag.epoch` is set to this
  # value, which is `>=` any reader's published epoch that could still
  # reach the just-detached pointer. See `reclaim.reclaimStart` for the
  # analogous pattern.
  #
  # Stack-local SC RMW (rather than `threadFence(moSequentiallyConsistent)`)
  # is required for TSAN compatibility: standalone SC thread fences are not
  # modelled by TSAN's vector clocks (`compiler-rt/lib/tsan/rtl/`
  # `tsan_interface_atomic.cpp`, `OpFence::Atomic` -> `FIXME: not implemented`).
  # SC RMWs are modelled correctly.
  var subscribeBarrier: Atomic[uint64]
  subscribeBarrier.store(0'u64, moRelaxed)
  discard subscribeBarrier.fetchAdd(0'u64, moSequentiallyConsistent)
  let epoch = handle.manager.globalEpoch.load(moAcquire)

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

  # Add object to bag with provided destructor.
  #
  # Stamp the bag with the LATEST retire epoch on every retire, not just on
  # bag creation. A bag accumulates retires across multiple `retire` calls
  # until it fills `LimboBagSize`, and the global epoch may advance between
  # them. If we left `bag.epoch` at the creation-time value, an object
  # retired at epoch K+2 would be reclaimed once `safeEpoch >= K+2` even
  # though the EBR invariant requires `safeEpoch >= K+4` (i.e. all readers
  # must have moved past K+2). The reclaimer's `bag.epoch < safeEpoch - 1`
  # check would then free a still-live pointer — exactly the
  # use-after-free TSAN reports as a race in `free` after `tryReclaim`.
  # Bumping `bag.epoch` to the current `epoch` is over-conservative for
  # earlier objects in the bag (they live longer than necessary) but
  # restores the safety invariant for later objects. `epoch` is monotonic
  # (globalEpoch only ever increases), so this is equivalent to
  # `max(bag.epoch, epoch)`.
  let bag = state.currentBag
  bag.epoch = epoch
  bag.objects[bag.count] = RetiredObject(data: p, destructor: destructor)
  inc bag.count

  # Consume r to create result
  Retired[MaxThreads](RetireContext[MaxThreads](r))

func handle*[MaxThreads: static int](
    r: RetireReady[MaxThreads]
): ThreadHandle[MaxThreads] =
  RetireContext[MaxThreads](r).handle
