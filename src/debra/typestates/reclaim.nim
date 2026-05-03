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
## * `reclaimStart(addr manager)` infers the slot from the thread-local
##   `threadLocalRegistered` / `threadLocalIdx` pair, additionally guarded
##   by `threadLocalManager` so a thread registered with manager A cannot
##   accidentally walk manager B's slot list. If the calling thread has
##   not been registered with `manager`, the returned context carries
##   `idx = -1` and `tryReclaim` short-circuits to 0 reclaimed (rather
##   than silently walking slot 0's bag list and racing with its owner).
##   Prefer the handle form `reclaimStart(handle)` regardless: it is
##   explicit and needs no thread-local lookup.
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
  ## If the calling thread has not been registered with this (or any) manager,
  ## the returned context carries `idx = -1`, so `tryReclaim` short-circuits to
  ## 0 reclaimed instead of mutating slot 0's bag list (which would race with
  ## that slot's owner). `threadLocalIdx` defaults to 0 and cannot by itself
  ## distinguish "registered at slot 0" from "never registered"; the
  ## companion `threadLocalRegistered` flag is the explicit registered-bit.
  ##
  ## In multi-manager scenarios `threadLocalIdx` and `threadLocalRegistered`
  ## describe the slot the calling thread holds with whichever manager it
  ## last registered with. Calling `reclaimStart(addr managerB)` from a
  ## thread registered with `managerA` would otherwise reuse A's slot index
  ## against B's bag list, racing with B's actual slot owner. The companion
  ## `threadLocalManager` pointer is therefore compared by identity here:
  ## on mismatch the context is returned with `idx = -1` and `tryReclaim`
  ## short-circuits to 0.
  ##
  ## See also: `debra/convenience.reclaimNow`_ for the one-shot wrapper.
  let idx =
    if threadLocalRegistered and threadLocalManager == cast[pointer](mgr):
      threadLocalIdx
    else:
      -1
  ReclaimStart[MaxThreads](
    ReclaimContext[MaxThreads](manager: mgr, idx: idx, globalEpoch: 0, safeEpoch: 0)
  )

proc loadEpochs*[MaxThreads: static int](
    s: ReclaimStart[MaxThreads]
): EpochsLoaded[MaxThreads] {.transition.} =
  ## Load global epoch and compute minimum epoch across pinned threads.
  ##
  ## Subscription read: an SC load of `globalEpoch` participates in the C11
  ## SC total order S, pairing with the SC RMW in `pin` to give EBR its
  ## StoreLoad ordering across threads. Without this, a reclaimer can read
  ## another thread's `pinned=false` even when that thread's pin RMW has
  ## already been issued, then proceed to free an object the still-pinning
  ## thread is about to read. The SC load ensures that for every concurrently
  ## pinning thread T, either (a) T's pin RMW is visible here (we observe
  ## `pinned=true`), or (b) T's subsequent load of the protected pointer
  ## happens after our prior writes — so T cannot have observed a still-live
  ## pointer to an object we are about to free.
  ##
  ## The SC RMW used to be issued against `manager.globalEpoch`
  ## (`globalEpoch.fetchAdd(0)`), but `globalEpoch` is a hot shared cache
  ## line and every reclaimer-side subscription bounced it across cores.
  ## Three properties were needed for the subscription handshake to be
  ## correct under TSAN:
  ##
  ## 1. **Hardware StoreLoad barrier.** A plain SC load is too weak — on
  ##    x86 it lowers to a bare `mov` and loses the `mfence` that an SC
  ##    fence would provide. An SC RMW lowers to a `lock`-prefixed
  ##    instruction on x86 and an `ldaxr`/`stlxr` seq-cst loop on ARM,
  ##    both of which are full StoreLoad barriers.
  ##
  ## 2. **Participation in C11's SC total order S.** The SC loads on
  ##    each thread's `pinned` flag (below) are in S. For the proof of
  ##    EBR safety to go through, the subscription point itself must be
  ##    in S so that pin RMWs published before our subscription are
  ##    visible. C11 §29.3 makes S a single total order across **every**
  ##    SC op, regardless of which atomic location it touches.
  ##
  ## 3. **TSAN vector-clock modelling.** Standalone SC fences are not
  ##    modelled by TSAN (see `compiler-rt/lib/tsan/rtl/`
  ##    `tsan_interface_atomic.cpp` `OpFence::Atomic` ->
  ##    `// FIXME: not implemented.`). SC RMWs are modelled correctly on
  ##    every atomic location, so the analyser sees the synchronisation.
  ##
  ## Properties (1) and (3) are properties of the *instruction*, not the
  ## operand location; property (2) is location-independent by C11
  ## construction. So a stack-local `Atomic[uint64]` gives us the same
  ## subscription point with no cross-thread cache traffic.
  var subscribeBarrier: Atomic[uint64]
  # Explicit zero-init. Default zero-init of `Atomic[uint64]` is already
  # correct in Nim, but the explicit store makes the intent obvious to
  # readers and to static-analysis tools that flag "use of uninitialized
  # atomic" on the SC RMW below.
  subscribeBarrier.store(0'u64, moRelaxed)
  discard subscribeBarrier.fetchAdd(0'u64, moSequentiallyConsistent)
  var ctx = ReclaimContext[MaxThreads](s)
  # `globalEpoch` is now just a value read; reading a slightly stale
  # epoch only makes `safeEpoch` conservatively lower, which is safe.
  # The acquire ordering is enough to pair with the release-stamping in
  # `advance.nim` and gives us the most-recent value any predecessor
  # thread has observed.
  ctx.globalEpoch = ctx.manager.globalEpoch.load(moAcquire)
  ctx.safeEpoch = ctx.globalEpoch

  # Subscribe to each thread's `pinned` flag with an SC load, not Acquire.
  # The pin side publishes via an SC RMW on `pinned`. SC ops on the *same*
  # atomic location are totally ordered in C11's S, so an SC load here is
  # guaranteed to read from a position in `pinned`'s modification order
  # that is consistent with S relative to every concurrent pin RMW. An
  # Acquire load is not in S, so the reclaimer could observe `pinned=false`
  # for a thread that has already published `pinned=true` — exactly the
  # race TSAN reports as a use-after-free in `free` after `tryReclaim`.
  # Crossbeam relies on the same property by packing pin+epoch into a
  # single SC-accessed word.
  for i in 0 ..< MaxThreads:
    if ctx.manager.threads[i].pinned.load(moSequentiallyConsistent):
      let threadEpoch = ctx.manager.threads[i].epoch.load(moAcquire)
      if threadEpoch < ctx.safeEpoch:
        ctx.safeEpoch = threadEpoch

  result = EpochsLoaded[MaxThreads](ctx)

func safeEpoch*[MaxThreads: static int](
    e: EpochsLoaded[MaxThreads]
): uint64 {.notATransition.} =
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
  ## mutations on `currentBag` and `limboBagTail`; those fields have no
  ## synchronization and are owned by the registered thread.
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

  # Walk from tail (oldest) toward head and reclaim eligible bags. Bags are
  # epoch-ordered (retire stamps `bag.epoch` on every insert and the list
  # advances monotonically), so the safe prefix is always contiguous starting
  # at the tail; the first not-yet-safe bag terminates the walk. Only the
  # calling thread mutates this list (via retire), so no synchronization is
  # needed.
  var bag = state.limboBagTail

  while bag != nil:
    if bag.epoch >= safeEpoch:
      # Not safe yet. Because bags are epoch-ordered, no later bag is safe
      # either; stop walking.
      break

    for j in 0 ..< bag.count:
      let obj = bag.objects[j]
      if obj.destructor != nil:
        obj.destructor(obj.data)
      inc count

    # Unlink from the tail. Because reclamation always strips a contiguous
    # prefix from the tail, the freed bag is the current tail by construction
    # — no `prevBag` bookkeeping is needed.
    let nextBag = bag.next
    state.limboBagTail = nextBag
    if state.currentBag == bag:
      state.currentBag = nextBag

    freeLimboBag(bag)
    bag = nextBag

  result = count
