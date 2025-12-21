## Registration typestate for thread registration.
##
## Handles thread registration with the DEBRA manager, ensuring threads
## properly claim slots in the thread array using lock-free CAS operations.

import atomics
import typestates

import ../types
import ../signal
import ../thread_id

type
  RegistrationContext*[MaxThreads: static int] = object of RootObj
    manager*: ptr DebraManager[MaxThreads]
    idx*: int

  Unregistered*[MaxThreads: static int] = distinct RegistrationContext[MaxThreads]
  Registered*[MaxThreads: static int] = distinct RegistrationContext[MaxThreads]
  RegistrationFull*[MaxThreads: static int] = distinct RegistrationContext[MaxThreads]

typestate RegistrationContext[MaxThreads: static int]:
  inheritsFromRootObj = true
  states Unregistered[MaxThreads], Registered[MaxThreads], RegistrationFull[MaxThreads]
  transitions:
    Unregistered[MaxThreads] ->
      Registered[MaxThreads] | RegistrationFull[MaxThreads] as RegisterResult[
        MaxThreads
      ]

proc unregistered*[MaxThreads: static int](
    mgr: ptr DebraManager[MaxThreads]
): Unregistered[MaxThreads] =
  ## Create unregistered context for a thread.
  Unregistered[MaxThreads](RegistrationContext[MaxThreads](manager: mgr, idx: -1))

proc register*[MaxThreads: static int](
    u: sink Unregistered[MaxThreads]
): RegisterResult[MaxThreads] {.transition.} =
  ## Try to register thread by claiming a slot. Returns Registered if successful,
  ## RegistrationFull if all slots are taken.
  let ctx = RegistrationContext[MaxThreads](u)
  let mgr = ctx.manager

  # Try each slot in order
  for i in 0 ..< MaxThreads:
    let bit = 1'u64 shl i
    var expected = mgr.activeThreadMask.load(moAcquire)

    # Keep trying while this slot is free
    while (expected and bit) == 0:
      let desired = expected or bit
      if mgr.activeThreadMask.compareExchangeWeak(
        expected, desired, moRelease, moAcquire
      ):
        # Successfully claimed slot i
        # Store thread ID for signaling
        mgr.threads[i].threadId.store(currentThreadId(), moRelease)
        # Set thread-local index for signal handler
        threadLocalIdx = i
        return
          RegisterResult[MaxThreads] ->
          Registered[MaxThreads](RegistrationContext[MaxThreads](manager: mgr, idx: i))
      # CAS failed, expected was updated, retry with new value

  # All slots taken
  RegisterResult[MaxThreads] ->
    RegistrationFull[MaxThreads](RegistrationContext[MaxThreads](manager: mgr, idx: -1))

func idx*[MaxThreads: static int](r: Registered[MaxThreads]): int =
  ## Get the thread slot index.
  RegistrationContext[MaxThreads](r).idx

func getHandle*[MaxThreads: static int](
    r: Registered[MaxThreads]
): ThreadHandle[MaxThreads] =
  ## Extract ThreadHandle for use in pin/unpin operations.
  let ctx = RegistrationContext[MaxThreads](r)
  ThreadHandle[MaxThreads](idx: ctx.idx, manager: ctx.manager)
