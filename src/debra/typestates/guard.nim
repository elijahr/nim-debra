## EpochGuard typestate for pin/unpin lifecycle.
##
## Ensures threads properly enter/exit critical sections.

import atomics
import typestates

import ../types

type
  EpochGuardContext*[MaxThreads: static int] = object of RootObj
    handle*: ThreadHandle[MaxThreads]
    epoch*: uint64

  Unpinned*[MaxThreads: static int] = distinct EpochGuardContext[MaxThreads]
  Pinned*[MaxThreads: static int] = distinct EpochGuardContext[MaxThreads]
  Neutralized*[MaxThreads: static int] = distinct EpochGuardContext[MaxThreads]

typestate EpochGuardContext[MaxThreads: static int]:
  inheritsFromRootObj = true
  states Unpinned[MaxThreads], Pinned[MaxThreads], Neutralized[MaxThreads]
  transitions:
    Unpinned[MaxThreads] -> Pinned[MaxThreads]
    Pinned[MaxThreads] -> Unpinned[MaxThreads] | Neutralized[MaxThreads] as UnpinResult[MaxThreads]
    Neutralized[MaxThreads] -> Unpinned[MaxThreads]


proc unpinned*[MaxThreads: static int](
  handle: ThreadHandle[MaxThreads]
): Unpinned[MaxThreads] =
  ## Create unpinned epoch guard context.
  Unpinned[MaxThreads](EpochGuardContext[MaxThreads](handle: handle, epoch: 0))


proc pin*[MaxThreads: static int](
  u: Unpinned[MaxThreads]
): Pinned[MaxThreads] {.transition.} =
  ## Enter critical section. Blocks reclamation of current epoch.
  var ctx = EpochGuardContext[MaxThreads](u)
  let mgr = ctx.handle.manager
  let idx = ctx.handle.idx

  ctx.epoch = mgr.globalEpoch.load(moAcquire)
  mgr.threads[idx].neutralized.store(false, moRelease)
  mgr.threads[idx].epoch.store(ctx.epoch, moRelease)
  mgr.threads[idx].pinned.store(true, moRelease)

  result = Pinned[MaxThreads](ctx)


proc unpin*[MaxThreads: static int](
  p: Pinned[MaxThreads]
): UnpinResult[MaxThreads] {.transition.} =
  ## Leave critical section. Returns Neutralized if signaled.
  let ctx = EpochGuardContext[MaxThreads](p)
  let mgr = ctx.handle.manager
  let idx = ctx.handle.idx

  mgr.threads[idx].pinned.store(false, moRelease)

  if mgr.threads[idx].neutralized.load(moAcquire):
    # Use the -> operator as shown in DSL reference
    UnpinResult[MaxThreads] -> Neutralized[MaxThreads](ctx)
  else:
    UnpinResult[MaxThreads] -> Unpinned[MaxThreads](ctx)


proc acknowledge*[MaxThreads: static int](
  n: Neutralized[MaxThreads]
): Unpinned[MaxThreads] {.transition.} =
  ## Acknowledge neutralization. Required before re-pinning.
  # Extract handle data from input directly to avoid copy issues
  let handle = EpochGuardContext[MaxThreads](n).handle
  handle.manager.threads[handle.idx].neutralized.store(false, moRelease)
  # Construct new Unpinned from handle
  Unpinned[MaxThreads](EpochGuardContext[MaxThreads](handle: handle, epoch: 0))


func epoch*[MaxThreads: static int](p: Pinned[MaxThreads]): uint64 =
  ## Get the epoch this thread is pinned at.
  EpochGuardContext[MaxThreads](p).epoch


func handle*[MaxThreads: static int](p: Pinned[MaxThreads]): ThreadHandle[MaxThreads] =
  ## Get the thread handle.
  EpochGuardContext[MaxThreads](p).handle
