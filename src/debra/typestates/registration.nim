# src/debra/typestates/registration.nim

## Thread registration typestate.
##
## Enforces correct sequencing for thread registration:
## Start -> FindSlot -> TryClaim -> Complete
##
## Key invariant: Slot is claimed via CAS BEFORE incrementing any counter.

import atomics
import std/posix

import ../types
import ../signal

type
  ThreadUnregistered* = object
    ## Thread has not registered with DEBRA manager.

  ThreadSlotFound*[MaxThreads: static int] = object
    ## Found available slot in thread array.
    slotIdx*: int

  ThreadRegistered*[MaxThreads: static int] = object
    ## Thread successfully registered. Can now use epoch operations.
    slotIdx*: int

  ThreadRegistrationFull* = object
    ## No slots available. Cannot register.

  RegistrationSlotCheckKind* = enum
    sThreadSlotFound
    sThreadRegistrationFull

  RegistrationSlotCheck*[MaxThreads: static int] = object
    ## Result of trying to find a registration slot.
    case kind*: RegistrationSlotCheckKind
    of sThreadSlotFound:
      threadslotfound*: ThreadSlotFound[MaxThreads]
    of sThreadRegistrationFull:
      threadregistrationfull*: ThreadRegistrationFull

  RegistrationClaimResultKind* = enum
    sThreadRegistered
    sThreadUnregistered

  RegistrationClaimResult*[MaxThreads: static int] = object
    ## Result of trying to claim a slot.
    case kind*: RegistrationClaimResultKind
    of sThreadRegistered:
      threadregistered*: ThreadRegistered[MaxThreads]
    of sThreadUnregistered:
      threadunregistered*: ThreadUnregistered


proc start*(): ThreadUnregistered {.inline.} =
  ## Begin thread registration.
  ThreadUnregistered()


proc findSlot*[MaxThreads: static int](
  op: ThreadUnregistered,
  manager: var DebraManager[MaxThreads]
): RegistrationSlotCheck[MaxThreads] {.inline.} =
  ## Find first available slot in thread bitmask.
  let mask = manager.activeThreadMask.load(moAcquire)

  for i in 0..<MaxThreads:
    if (mask and (1'u64 shl i)) == 0:
      return RegistrationSlotCheck[MaxThreads](
        kind: sThreadSlotFound,
        threadslotfound: ThreadSlotFound[MaxThreads](slotIdx: i)
      )

  RegistrationSlotCheck[MaxThreads](
    kind: sThreadRegistrationFull,
    threadregistrationfull: ThreadRegistrationFull()
  )


proc tryClaim*[MaxThreads: static int](
  op: ThreadSlotFound[MaxThreads],
  manager: var DebraManager[MaxThreads]
): RegistrationClaimResult[MaxThreads] {.inline.} =
  ## CAS to claim the slot. Failure = retry from start.
  let bit = 1'u64 shl op.slotIdx
  var expected = manager.activeThreadMask.load(moAcquire)

  while (expected and bit) == 0:
    let desired = expected or bit
    if manager.activeThreadMask.compareExchangeWeak(expected, desired, moRelease, moAcquire):
      # Store OS thread ID for signaling
      manager.threads[op.slotIdx].osThreadId.store(getThreadId().Pid, moRelease)
      # Set thread-local index for signal handler
      threadLocalIdx = op.slotIdx
      return RegistrationClaimResult[MaxThreads](
        kind: sThreadRegistered,
        threadregistered: ThreadRegistered[MaxThreads](slotIdx: op.slotIdx)
      )

  # Slot was taken by another thread, retry from start
  RegistrationClaimResult[MaxThreads](
    kind: sThreadUnregistered,
    threadunregistered: ThreadUnregistered()
  )


proc extractHandle*[MaxThreads: static int](
  op: ThreadRegistered[MaxThreads],
  manager: var DebraManager[MaxThreads]
): ThreadHandle[MaxThreads] {.inline.} =
  ## Extract the thread handle for use in pin/unpin operations.
  ThreadHandle[MaxThreads](idx: op.slotIdx, manager: addr manager)


proc extractIdx*[MaxThreads: static int](
  op: ThreadRegistered[MaxThreads]
): int {.inline.} =
  ## Extract just the slot index.
  op.slotIdx
