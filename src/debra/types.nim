# src/debra/types.nim

## Core types for DEBRA+ implementation.

import ./atomics

import ./constants
import ./limbo
import ./thread_id

type
  ThreadState*[MaxThreads: static int] = object
    ## Per-thread state tracked by the DEBRA manager.
    epoch* {.align: 8.}: Atomic[uint64] ## Last observed global epoch.
    pinned* {.align: 8.}: Atomic[bool]
      ## Whether thread is currently in a critical section.
    neutralized* {.align: 8.}: Atomic[bool]
      ## Whether thread was force-unpinned by signal.
    threadId* {.align: 8.}: Atomic[ThreadId] ## Thread identifier for sending signals.
    # Limbo bag fields
    currentBag*: ptr LimboBag ## Currently filling limbo bag.
    limboBagTail*: ptr LimboBag ## Tail of limbo bag list (oldest).
    # Cadence counter for `advanceEvery` (owned by the registered thread, no
    # cross-thread access; non-atomic).
    advanceCounter*: uint64
    # Pad to a full cache line so adjacent slots in `DebraManager.threads`
    # do not share a cache line. The `{.align: CacheLineBytes.}` on the
    # `threads` array only aligns the first element; without per-slot
    # padding, every slot after the first floats to its natural alignment
    # and adjacent slots would false-share on every atomic write. The live
    # fields above total 56 bytes today (4 atomics at 8 bytes, 2 pointers
    # at 8 bytes, `advanceCounter` at 8 bytes); pad to `CacheLineBytes` so
    # 64-byte (x86_64, AArch64) and 128-byte (Apple Silicon, PowerPC, or
    # `-d:CacheLineBytes=128`) targets both work without manual edits.
    # The static assert below catches any layout drift.
    cacheLinePad: array[CacheLineBytes - 56, byte]

  DebraManager*[MaxThreads: static int] = object
    ## Coordinates epoch-based reclamation across threads.
    globalEpoch* {.align: CacheLineBytes.}: Atomic[uint64] ## Global epoch counter.
    activeThreadMask* {.align: CacheLineBytes.}: Atomic[uint64]
      ## Bitmask of registered threads.
    threads* {.align: CacheLineBytes.}: array[MaxThreads, ThreadState[MaxThreads]]
      ## Per-thread state. Cache-line aligned to prevent false sharing
      ## across the per-thread slots (each slot is owned by a different
      ## thread, so adjacent slots sharing a cache line would cause
      ## false-sharing on every atomic write).

  ThreadHandle*[MaxThreads: static int] = object
    ## Handle for a registered thread. Required for pin/unpin.
    idx*: int ## Index into the threads array.
    manager*: ptr DebraManager[MaxThreads] ## Pointer to the manager.

  DebraRegistrationError* = object of CatchableError
    ## Raised when thread registration fails (e.g., max threads reached).

# The cache-line alignment of `DebraManager.threads` only prevents false
# sharing if each `ThreadState` is itself an exact multiple of the cache
# line. If this static assertion ever fails, switch to padding `ThreadState`
# (e.g. add a `_pad: array[CacheLineBytes - sizeof(...), byte]` field, or
# wrap each slot in a padded object).
static:
  assert sizeof(ThreadState[DefaultMaxThreads]) mod CacheLineBytes == 0,
    "ThreadState size (" & $sizeof(ThreadState[DefaultMaxThreads]) &
      ") must be a multiple of CacheLineBytes (" & $CacheLineBytes &
      ") to prevent false sharing across DebraManager.threads slots"

proc initDebraManager*[MaxThreads: static int](): DebraManager[MaxThreads] =
  ## Initialize a new DEBRA+ manager.
  ##
  ## The global epoch starts at 1 (not 0) so that epoch 0 can represent
  ## "never observed" in thread state.
  result.globalEpoch.store(1'u64, moRelaxed)
  result.activeThreadMask.store(0'u64, moRelaxed)
  for i in 0 ..< MaxThreads:
    result.threads[i].epoch.store(0'u64, moRelaxed)
    result.threads[i].pinned.store(false, moRelaxed)
    result.threads[i].neutralized.store(false, moRelaxed)
    result.threads[i].threadId.store(InvalidThreadId, moRelaxed)
    result.threads[i].currentBag = nil
    result.threads[i].limboBagTail = nil
    result.threads[i].advanceCounter = 0'u64

proc `=destroy`*[MaxThreads: static int](manager: var DebraManager[MaxThreads]) =
  ## Drain all per-thread limbo bags when the manager goes out of scope.
  ##
  ## Worker threads must have joined before the manager is destroyed (the
  ## bag lists are owned by their respective slots without synchronization,
  ## so concurrent retire during destruction is undefined). Process-exit
  ## and end-of-scope cleanup is the typical caller.
  ##
  ## Without this, retire-but-not-yet-reclaimed objects (and the limbo bags
  ## that hold them) leak under ASAN at exit. With aggressive Manual
  ## strategies or short-lived managers, the leak is observable.
  for i in 0 ..< MaxThreads:
    var bag = manager.threads[i].limboBagTail
    while bag != nil:
      let nextBag = bag.next
      reclaimBag(bag)
      bag = nextBag
    manager.threads[i].currentBag = nil
    manager.threads[i].limboBagTail = nil
