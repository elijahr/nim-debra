## ThreadSlot typestate for thread slot lifecycle.
##
## Tracks the lifecycle of a thread slot in the DEBRA manager:
## - Free: Slot is available for claiming
## - Claiming: Thread is attempting to claim the slot
## - Active: Slot is actively in use by a thread
## - Draining: Thread is unregistering, draining limbo bags
## - Free: Slot released back to pool

import typestates

import ../types

type
  SlotContext*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] = object of RootObj
    idx*: int
    manager*: ptr DebraManager[MaxThreads, CC]

  Free*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct SlotContext[MaxThreads, CC]
  Claiming*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct SlotContext[MaxThreads, CC]
  Active*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct SlotContext[MaxThreads, CC]
  Draining*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct SlotContext[MaxThreads, CC]

typestate SlotContext[MaxThreads: static int, CC: static PinScopeCardinality]:
  inheritsFromRootObj = true
  defaults:
    CC:
      ccSingle
  states Free[MaxThreads, CC],
    Claiming[MaxThreads, CC], Active[MaxThreads, CC], Draining[MaxThreads, CC]
  transitions:
    Free[MaxThreads, CC] -> Claiming[MaxThreads, CC]
    Claiming[MaxThreads, CC] -> Active[MaxThreads, CC]
    Active[MaxThreads, CC] -> Draining[MaxThreads, CC]
    Draining[MaxThreads, CC] -> Free[MaxThreads, CC]

proc freeSlot*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    idx: int, mgr: ptr DebraManager[MaxThreads, CC]
): Free[MaxThreads, CC] =
  ## Create a free slot context.
  Free[MaxThreads, CC](SlotContext[MaxThreads, CC](idx: idx, manager: mgr))

proc claim*[MaxThreads: static int, CC: static PinScopeCardinality](
    f: sink Free[MaxThreads, CC]
): Claiming[MaxThreads, CC] {.transition.} =
  ## Begin claiming this slot. Transition to Claiming state.
  Claiming[MaxThreads, CC](SlotContext[MaxThreads, CC](f))

proc activate*[MaxThreads: static int, CC: static PinScopeCardinality](
    c: sink Claiming[MaxThreads, CC]
): Active[MaxThreads, CC] {.transition.} =
  ## Complete slot claim. Transition to Active state.
  ## This is where the slot becomes fully owned by a thread.
  Active[MaxThreads, CC](SlotContext[MaxThreads, CC](c))

proc drain*[MaxThreads: static int, CC: static PinScopeCardinality](
    a: sink Active[MaxThreads, CC]
): Draining[MaxThreads, CC] {.transition.} =
  ## Begin unregistration. Transition to Draining state.
  ## Thread will drain its limbo bags before releasing the slot.
  Draining[MaxThreads, CC](SlotContext[MaxThreads, CC](a))

proc release*[MaxThreads: static int, CC: static PinScopeCardinality](
    d: sink Draining[MaxThreads, CC]
): Free[MaxThreads, CC] {.transition.} =
  ## Release slot back to free pool. Transition back to Free state.
  ## This completes the lifecycle, making the slot available for reuse.
  Free[MaxThreads, CC](SlotContext[MaxThreads, CC](d))

func idx*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Active[MaxThreads, CC]
): int {.notATransition.} =
  ## Get the slot index from Active state.
  SlotContext[MaxThreads, CC](s).idx

func idx*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Draining[MaxThreads, CC]
): int {.notATransition.} =
  ## Get the slot index from Draining state.
  SlotContext[MaxThreads, CC](s).idx

func manager*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Active[MaxThreads, CC]
): ptr DebraManager[MaxThreads, CC] {.notATransition.} =
  ## Get the manager pointer from Active state.
  SlotContext[MaxThreads, CC](s).manager

func manager*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Draining[MaxThreads, CC]
): ptr DebraManager[MaxThreads, CC] {.notATransition.} =
  ## Get the manager pointer from Draining state.
  SlotContext[MaxThreads, CC](s).manager
