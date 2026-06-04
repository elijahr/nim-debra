## Registration typestate for thread registration.
##
## Handles thread registration with the DEBRA manager, ensuring threads
## properly claim slots in the thread array using lock-free CAS operations.
##
## The typestate carries two static generic-param axes:
##
## - `MaxThreads: static int` — capacity of the manager's thread array.
## - `CC: static PinScopeCardinality = ccSingle` — consumer-cardinality
##   phantom mirroring `DebraManager` / `ThreadHandle`. Default `ccSingle`
##   matches the 0.7.x call shape, so existing call sites that spell only
##   `MaxThreads` continue to bind cleanly.
##
## Codegen-emitted helpers (variant type `RegisterResult`, `=copy` hooks,
## `state()` procs, `$` overloads, `match` macros) inherit `CC = ccSingle`
## via the typestate macro's `defaults:` body section (typestates 0.9.2+).

import ../atomics
import typestates

import ../types
import ../signal
import ../thread_id

# `PinScopeCardinality` reaches this module via `../types` (re-exported
# from `./cardinality`).

type
  RegistrationContext*[
    MaxThreads: static int, CC: static PinScopeCardinality = ccSingle
  ] = object of RootObj
    manager*: ptr DebraManager[MaxThreads, CC]
    idx*: int

  Unregistered*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct RegistrationContext[MaxThreads, CC]

  Registered*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct RegistrationContext[MaxThreads, CC]

  RegistrationFull*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct RegistrationContext[MaxThreads, CC]

typestate RegistrationContext[MaxThreads: static int, CC: static PinScopeCardinality]:
  inheritsFromRootObj = true
  opaqueStates = true
  defaults:
    CC:
      ccSingle
  states:
    Unregistered[MaxThreads, CC]
    Registered[MaxThreads, CC]
    RegistrationFull[MaxThreads, CC]
  initial:
    Unregistered[MaxThreads, CC]
  terminal:
    Registered[MaxThreads, CC]
    RegistrationFull[MaxThreads, CC]
  transitions:
    Unregistered[MaxThreads, CC] ->
      Registered[MaxThreads, CC] | RegistrationFull[MaxThreads, CC] as
      RegisterResult[MaxThreads, CC]

proc unregistered*[MaxThreads: static int, CC: static PinScopeCardinality](
    mgr: ptr DebraManager[MaxThreads, CC]
): Unregistered[MaxThreads, CC] =
  ## Create unregistered context for a thread.
  Unregistered[MaxThreads, CC](
    RegistrationContext[MaxThreads, CC](manager: mgr, idx: -1)
  )

proc register*[MaxThreads: static int, CC: static PinScopeCardinality](
    u: sink Unregistered[MaxThreads, CC]
): RegisterResult[MaxThreads, CC] {.transition.} =
  ## Try to register thread by claiming a slot. Returns Registered if successful,
  ## RegistrationFull if all slots are taken.
  let ctx = RegistrationContext[MaxThreads, CC](u)
  let mgr = ctx.manager

  # Try each slot in order
  for i in 0 ..< MaxThreads:
    let bit = 1'u64 shl i
    var expected = mgr.activeThreadMask.load(moAcquire)

    # Keep trying while this slot is free
    while (expected and bit) == 0:
      let desired = expected or bit
      if mgr.activeThreadMask.compareExchangeWeak(
        expected, desired, moAcquireRelease, moAcquire
      ):
        # Successfully claimed slot i
        when defined(windows):
          # If this slot was previously unregistered, its outgoing
          # handle is stashed in `handlesPendingClose[i]` awaiting the
          # manager `=destroy` drain. Re-claiming the slot would
          # overwrite that entry on the next `unregisterThread`,
          # silently leaking the previous handle. Drain on claim
          # instead: by this point the prior owner has already
          # cleared its `threadId` (release-store visible via the
          # mask-bit acquire above) and any scanner that loaded the
          # old handle has already either used it or skipped it; no
          # subsequent scanner can see it (the mask bit was clear).
          # Closing here bounds the queue at one entry per live slot
          # (gemini cycle-37).
          var pending = mgr.handlesPendingClose[i]
          if pending.isValid():
            pending.closeThreadId()
            mgr.handlesPendingClose[i] = InvalidThreadId
        # Store thread ID for signaling
        mgr.threads[i].threadId.store(currentThreadId(), moRelease)
        # Set thread-local index for signal handler. Both `threadLocalIdx`
        # and `threadLocalRegistered` must be set: the bare index can't
        # distinguish "registered at slot 0" from "never registered" since
        # threadvars default to zero.
        threadLocalIdx = i
        threadLocalRegistered = true
        threadLocalManager = cast[pointer](mgr)
        return
          RegisterResult[MaxThreads, CC] ->
          Registered[MaxThreads, CC](
            RegistrationContext[MaxThreads, CC](manager: mgr, idx: i)
          )
      # CAS failed, expected was updated, retry with new value

  # All slots taken
  RegisterResult[MaxThreads, CC] ->
    RegistrationFull[MaxThreads, CC](
      RegistrationContext[MaxThreads, CC](manager: mgr, idx: -1)
    )

func idx*[MaxThreads: static int, CC: static PinScopeCardinality](
    r: Registered[MaxThreads, CC]
): int {.notATransition.} =
  ## Get the thread slot index.
  RegistrationContext[MaxThreads, CC](r).idx

func getHandle*[MaxThreads: static int, CC: static PinScopeCardinality](
    r: Registered[MaxThreads, CC]
): ThreadHandle[MaxThreads, CC] =
  ## Extract ThreadHandle for use in pin/unpin operations.
  let ctx = RegistrationContext[MaxThreads, CC](r)
  ThreadHandle[MaxThreads, CC](idx: ctx.idx, manager: ctx.manager)
