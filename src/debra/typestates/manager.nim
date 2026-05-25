## DebraManager lifecycle typestate.
##
## Ensures manager is initialized before use and properly shut down.

import ../atomics
import typestates

import ../types
import ../limbo
import ../thread_id

type
  ManagerContext*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] = object of RootObj
    manager*: ptr DebraManager[MaxThreads, CC]

  ManagerUninitialized*[
    MaxThreads: static int, CC: static PinScopeCardinality = ccSingle
  ] = distinct ManagerContext[MaxThreads, CC]
  ManagerReady*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct ManagerContext[MaxThreads, CC]
  ManagerShutdown*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct ManagerContext[MaxThreads, CC]

typestate ManagerContext[MaxThreads: static int, CC: static PinScopeCardinality]:
  inheritsFromRootObj = true
  opaqueStates = true
  defaults:
    CC:
      ccSingle
  states ManagerUninitialized[MaxThreads, CC],
    ManagerReady[MaxThreads, CC], ManagerShutdown[MaxThreads, CC]
  initial:
    ManagerUninitialized[MaxThreads, CC]
  terminal:
    ManagerShutdown[MaxThreads, CC]
  transitions:
    ManagerUninitialized[MaxThreads, CC] -> ManagerReady[MaxThreads, CC]
    ManagerReady[MaxThreads, CC] -> ManagerShutdown[MaxThreads, CC]

proc uninitializedManager*[
    MaxThreads: static int, CC: static PinScopeCardinality = ccSingle
](mgr: ptr DebraManager[MaxThreads, CC]): ManagerUninitialized[MaxThreads, CC] =
  ## Wrap a manager pointer as uninitialized.
  ManagerUninitialized[MaxThreads, CC](ManagerContext[MaxThreads, CC](manager: mgr))

proc initialize*[MaxThreads: static int, CC: static PinScopeCardinality](
    m: sink ManagerUninitialized[MaxThreads, CC]
): ManagerReady[MaxThreads, CC] {.transition.} =
  ## Initialize the manager. Sets epoch to 1, clears all state.
  let ctx = ManagerContext[MaxThreads, CC](m)
  let mgr = ctx.manager
  mgr.globalEpoch.store(1'u64, moRelaxed)
  mgr.activeThreadMask.store(0'u64, moRelaxed)
  mgr.boundClients.store(0, moRelaxed)
  for i in 0 ..< MaxThreads:
    mgr.threads[i].epoch.store(0'u64, moRelaxed)
    mgr.threads[i].pinned.store(false, moRelaxed)
    mgr.threads[i].neutralized.store(false, moRelaxed)
    mgr.threads[i].threadId.store(InvalidThreadId, moRelaxed)
    mgr.threads[i].currentBag = nil
    mgr.threads[i].limboBagTail = nil
  ManagerReady[MaxThreads, CC](ManagerContext[MaxThreads, CC](manager: mgr))

proc shutdown*[MaxThreads: static int, CC: static PinScopeCardinality](
    m: sink ManagerReady[MaxThreads, CC]
): ManagerShutdown[MaxThreads, CC] {.transition.} =
  ## Shutdown manager. Reclaims all remaining limbo bags.
  let ctx = ManagerContext[MaxThreads, CC](m)
  let mgr = ctx.manager
  for i in 0 ..< MaxThreads:
    # Reclaim all limbo bags for this thread
    var bag = mgr.threads[i].currentBag
    while bag != nil:
      let next = bag.next
      try:
        reclaimBag(bag)
      except Exception:
        discard # Ignore destructor exceptions during shutdown
      bag = next
    mgr.threads[i].currentBag = nil
    mgr.threads[i].limboBagTail = nil
  ManagerShutdown[MaxThreads, CC](ManagerContext[MaxThreads, CC](manager: mgr))

func getManager*[MaxThreads: static int, CC: static PinScopeCardinality](
    m: ManagerReady[MaxThreads, CC]
): ptr DebraManager[MaxThreads, CC] {.notATransition.} =
  ## Get the underlying manager pointer.
  ManagerContext[MaxThreads, CC](m).manager
