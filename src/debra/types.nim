# src/debra/types.nim

## Core types for DEBRA+ implementation.

import atomics
import std/posix

import ./constants
import ./limbo

type
  ThreadState*[MaxThreads: static int] = object
    ## Per-thread state tracked by the DEBRA manager.
    epoch* {.align: 8.}: Atomic[uint64]
      ## Last observed global epoch.
    pinned* {.align: 8.}: Atomic[bool]
      ## Whether thread is currently in a critical section.
    neutralized* {.align: 8.}: Atomic[bool]
      ## Whether thread was force-unpinned by signal.
    osThreadId* {.align: 8.}: Atomic[Pid]
      ## OS thread ID for sending signals.
    # Limbo bag fields
    currentBag*: ptr LimboBag
      ## Currently filling limbo bag.
    limboBagHead*: ptr LimboBag
      ## Head of limbo bag list (newest).
    limboBagTail*: ptr LimboBag
      ## Tail of limbo bag list (oldest).

  DebraManager*[MaxThreads: static int] = object
    ## Coordinates epoch-based reclamation across threads.
    globalEpoch* {.align: CacheLineBytes.}: Atomic[uint64]
      ## Global epoch counter.
    activeThreadMask* {.align: CacheLineBytes.}: Atomic[uint64]
      ## Bitmask of registered threads.
    threads*: array[MaxThreads, ThreadState[MaxThreads]]
      ## Per-thread state.

  ThreadHandle*[MaxThreads: static int] = object
    ## Handle for a registered thread. Required for pin/unpin.
    idx*: int
      ## Index into the threads array.
    manager*: ptr DebraManager[MaxThreads]
      ## Pointer to the manager.

  DebraRegistrationError* = object of CatchableError
    ## Raised when thread registration fails (e.g., max threads reached).

proc initDebraManager*[MaxThreads: static int](): DebraManager[MaxThreads] =
  ## Initialize a new DEBRA+ manager.
  ##
  ## The global epoch starts at 1 (not 0) so that epoch 0 can represent
  ## "never observed" in thread state.
  result.globalEpoch.store(1'u64, moRelaxed)
  result.activeThreadMask.store(0'u64, moRelaxed)
  for i in 0..<MaxThreads:
    result.threads[i].epoch.store(0'u64, moRelaxed)
    result.threads[i].pinned.store(false, moRelaxed)
    result.threads[i].neutralized.store(false, moRelaxed)
    result.threads[i].osThreadId.store(Pid(0), moRelaxed)
    result.threads[i].currentBag = nil
    result.threads[i].limboBagHead = nil
    result.threads[i].limboBagTail = nil
