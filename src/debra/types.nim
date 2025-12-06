# src/debra/types.nim

## Core types for DEBRA+ implementation.

import atomics
import std/posix

import ./constants

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
