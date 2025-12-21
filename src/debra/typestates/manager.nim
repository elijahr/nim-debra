## DebraManager lifecycle typestate.
##
## Ensures manager is initialized before use and properly shut down.

import atomics
import typestates

import ../types
import ../limbo
import ../thread_id

type
  ManagerContext*[MaxThreads: static int] = object of RootObj
    manager*: ptr DebraManager[MaxThreads]

  ManagerUninitialized*[MaxThreads: static int] = distinct ManagerContext[MaxThreads]
  ManagerReady*[MaxThreads: static int] = distinct ManagerContext[MaxThreads]
  ManagerShutdown*[MaxThreads: static int] = distinct ManagerContext[MaxThreads]

typestate ManagerContext[MaxThreads: static int]:
  inheritsFromRootObj = true
  states ManagerUninitialized[MaxThreads],
    ManagerReady[MaxThreads], ManagerShutdown[MaxThreads]
  transitions:
    ManagerUninitialized[MaxThreads] -> ManagerReady[MaxThreads]
    ManagerReady[MaxThreads] -> ManagerShutdown[MaxThreads]

proc uninitializedManager*[MaxThreads: static int](
    mgr: ptr DebraManager[MaxThreads]
): ManagerUninitialized[MaxThreads] =
  ## Wrap a manager pointer as uninitialized.
  ManagerUninitialized[MaxThreads](ManagerContext[MaxThreads](manager: mgr))

proc initialize*[MaxThreads: static int](
    m: sink ManagerUninitialized[MaxThreads]
): ManagerReady[MaxThreads] {.transition.} =
  ## Initialize the manager. Sets epoch to 1, clears all state.
  let ctx = ManagerContext[MaxThreads](m)
  let mgr = ctx.manager
  mgr.globalEpoch.store(1'u64, moRelaxed)
  mgr.activeThreadMask.store(0'u64, moRelaxed)
  for i in 0 ..< MaxThreads:
    mgr.threads[i].epoch.store(0'u64, moRelaxed)
    mgr.threads[i].pinned.store(false, moRelaxed)
    mgr.threads[i].neutralized.store(false, moRelaxed)
    mgr.threads[i].threadId.store(InvalidThreadId, moRelaxed)
    mgr.threads[i].currentBag = nil
    mgr.threads[i].limboBagHead = nil
    mgr.threads[i].limboBagTail = nil
  ManagerReady[MaxThreads](ManagerContext[MaxThreads](manager: mgr))

proc shutdown*[MaxThreads: static int](
    m: sink ManagerReady[MaxThreads]
): ManagerShutdown[MaxThreads] {.transition.} =
  ## Shutdown manager. Reclaims all remaining limbo bags.
  let ctx = ManagerContext[MaxThreads](m)
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
    mgr.threads[i].limboBagHead = nil
    mgr.threads[i].limboBagTail = nil
  ManagerShutdown[MaxThreads](ManagerContext[MaxThreads](manager: mgr))

func getManager*[MaxThreads: static int](
    m: ManagerReady[MaxThreads]
): ptr DebraManager[MaxThreads] =
  ## Get the underlying manager pointer.
  ManagerContext[MaxThreads](m).manager
