# src/debra/types.nim

## Core types for DEBRA+ implementation.

import ./atomics

import ./constants
import ./limbo
import ./thread_id

type
  ThreadStateLive[MaxThreads: static int] = object
    ## Sibling type used SOLELY to derive the live-field byte total for
    ## `ThreadState.cacheLinePad`. Must mirror `ThreadState`'s fields
    ## exactly, minus `cacheLinePad`. The `static: assert` block below
    ## catches drift between the two declarations.
    epoch {.align: 8.}: Atomic[uint64]
    pinned {.align: 8.}: Atomic[bool]
    neutralized {.align: 8.}: Atomic[bool]
    threadId {.align: 8.}: Atomic[ThreadId]
    currentBag: ptr LimboBag
    limboBagTail: ptr LimboBag
    advanceCounter: uint64

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
    # and adjacent slots would false-share on every atomic write.
    #
    # Padding size is derived from `sizeof(ThreadStateLive[MaxThreads])`
    # rather than a hand-summed constant, so adding/removing fields above
    # automatically resizes the pad (provided the same change is mirrored
    # into `ThreadStateLive`). The outer `mod CacheLineBytes` collapses
    # the "exactly aligned" case to a 0-byte array instead of a full
    # extra cache line. Works for 64-byte (x86_64, AArch64) and 128-byte
    # (Apple Silicon, PowerPC, `-d:CacheLineBytes=128`) targets without
    # manual edits. The static asserts below catch any drift.
    cacheLinePad: array[
      (CacheLineBytes - sizeof(ThreadStateLive[MaxThreads]) mod CacheLineBytes) mod
        CacheLineBytes,
      byte,
    ]

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
# line. The first assertion below verifies that. The second assertion
# verifies that `ThreadStateLive` mirrors `ThreadState`'s live fields
# (everything except `cacheLinePad`); if a field is added/removed/resized
# in one type but not the other, the drift trips a clear compile error
# instead of silently producing the wrong padding size.
static:
  assert sizeof(ThreadState[DefaultMaxThreads]) mod CacheLineBytes == 0,
    "ThreadState size (" & $sizeof(ThreadState[DefaultMaxThreads]) &
      ") must be a multiple of CacheLineBytes (" & $CacheLineBytes &
      ") to prevent false sharing across DebraManager.threads slots"
  # Drift check: ThreadStateLive must contain the SAME fields as ThreadState
  # minus cacheLinePad. If you add a field to one, add it to the other.
  assert sizeof(ThreadState[DefaultMaxThreads]) -
    sizeof(ThreadState[DefaultMaxThreads].cacheLinePad) ==
    sizeof(ThreadStateLive[DefaultMaxThreads]),
    "ThreadStateLive (" & $sizeof(ThreadStateLive[DefaultMaxThreads]) &
      " bytes) is out of sync with ThreadState's live fields (" &
      $(
        sizeof(ThreadState[DefaultMaxThreads]) -
        sizeof(ThreadState[DefaultMaxThreads].cacheLinePad)
      ) & " bytes); update ThreadStateLive to mirror ThreadState"

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
