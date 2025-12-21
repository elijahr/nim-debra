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
  SlotContext*[MaxThreads: static int] = object of RootObj
    idx*: int
    manager*: ptr DebraManager[MaxThreads]

  Free*[MaxThreads: static int] = distinct SlotContext[MaxThreads]
  Claiming*[MaxThreads: static int] = distinct SlotContext[MaxThreads]
  Active*[MaxThreads: static int] = distinct SlotContext[MaxThreads]
  Draining*[MaxThreads: static int] = distinct SlotContext[MaxThreads]

typestate SlotContext[MaxThreads: static int]:
  inheritsFromRootObj = true
  states Free[MaxThreads],
    Claiming[MaxThreads], Active[MaxThreads], Draining[MaxThreads]
  transitions:
    Free[MaxThreads] -> Claiming[MaxThreads]
    Claiming[MaxThreads] -> Active[MaxThreads]
    Active[MaxThreads] -> Draining[MaxThreads]
    Draining[MaxThreads] -> Free[MaxThreads]

proc freeSlot*[MaxThreads: static int](
    idx: int, mgr: ptr DebraManager[MaxThreads]
): Free[MaxThreads] =
  ## Create a free slot context.
  Free[MaxThreads](SlotContext[MaxThreads](idx: idx, manager: mgr))

proc claim*[MaxThreads: static int](
    f: sink Free[MaxThreads]
): Claiming[MaxThreads] {.transition.} =
  ## Begin claiming this slot. Transition to Claiming state.
  Claiming[MaxThreads](SlotContext[MaxThreads](f))

proc activate*[MaxThreads: static int](
    c: sink Claiming[MaxThreads]
): Active[MaxThreads] {.transition.} =
  ## Complete slot claim. Transition to Active state.
  ## This is where the slot becomes fully owned by a thread.
  Active[MaxThreads](SlotContext[MaxThreads](c))

proc drain*[MaxThreads: static int](
    a: sink Active[MaxThreads]
): Draining[MaxThreads] {.transition.} =
  ## Begin unregistration. Transition to Draining state.
  ## Thread will drain its limbo bags before releasing the slot.
  Draining[MaxThreads](SlotContext[MaxThreads](a))

proc release*[MaxThreads: static int](
    d: sink Draining[MaxThreads]
): Free[MaxThreads] {.transition.} =
  ## Release slot back to free pool. Transition back to Free state.
  ## This completes the lifecycle, making the slot available for reuse.
  Free[MaxThreads](SlotContext[MaxThreads](d))

func idx*[MaxThreads: static int](s: Active[MaxThreads]): int =
  ## Get the slot index from Active state.
  SlotContext[MaxThreads](s).idx

func idx*[MaxThreads: static int](s: Draining[MaxThreads]): int =
  ## Get the slot index from Draining state.
  SlotContext[MaxThreads](s).idx

func manager*[MaxThreads: static int](
    s: Active[MaxThreads]
): ptr DebraManager[MaxThreads] =
  ## Get the manager pointer from Active state.
  SlotContext[MaxThreads](s).manager

func manager*[MaxThreads: static int](
    s: Draining[MaxThreads]
): ptr DebraManager[MaxThreads] =
  ## Get the manager pointer from Draining state.
  SlotContext[MaxThreads](s).manager
