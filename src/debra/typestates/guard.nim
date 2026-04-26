## EpochGuard typestate for pin/unpin lifecycle.
##
## Ensures threads properly enter/exit critical sections.
##
## ## Pitfalls
##
## * The `Unpinned` -> `Pinned` -> `Unpinned`/`Neutralized` typestate sequence
##   must be respected. Calling `pin` on a handle that is already pinned at
##   the slot level (the manager's `threads[idx].pinned` flag is true) leaves
##   the slot inconsistent. Use `withPin` (in `debra/convenience`) for the
##   common path; reach for the typestate API only when you need finer control.
## * If `unpin` returns `Neutralized`, the thread was signaled while inside
##   the critical section. Call `acknowledge` before re-pinning. Skipping
##   `acknowledge` will leave the slot's `neutralized` flag set, and the
##   next `pin`/`unpin` cycle will misreport state.
## * `Pinned[MT]` carries the captured `epoch` field; do not mutate the
##   manager's global epoch under the assumption a particular `Pinned` value
##   tracks it. Advance the manager epoch on the worker side, then re-pin to
##   refresh.
##
## ## See also
##
## * `debra/convenience.withPin`_ - the recommended high-level wrapper.
## * `debra/typestates/retire`_ - `RetireReady` constructed from `Pinned`.

import ../atomics
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
  consumeOnTransition = false # Allow values to be passed across typestate boundaries
  states Unpinned[MaxThreads], Pinned[MaxThreads], Neutralized[MaxThreads]
  transitions:
    Unpinned[MaxThreads] -> Pinned[MaxThreads]
    Pinned[MaxThreads] ->
      Unpinned[MaxThreads] | Neutralized[MaxThreads] as UnpinResult[MaxThreads]
    Neutralized[MaxThreads] -> Unpinned[MaxThreads]

proc unpinned*[MaxThreads: static int](
    handle: ThreadHandle[MaxThreads]
): Unpinned[MaxThreads] =
  ## Create unpinned epoch guard context.
  Unpinned[MaxThreads](EpochGuardContext[MaxThreads](handle: handle, epoch: 0))

proc pin*[MaxThreads: static int](
    u: sink Unpinned[MaxThreads]
): Pinned[MaxThreads] {.transition.} =
  ## Enter critical section. Blocks reclamation of current epoch.
  runnableExamples:
    import debra
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let pinned = unpinned(handle).pin()
    discard pinned.unpin()
  var ctx = EpochGuardContext[MaxThreads](u)
  let mgr = ctx.handle.manager
  let idx = ctx.handle.idx

  ctx.epoch = mgr.globalEpoch.load(moAcquire)
  mgr.threads[idx].neutralized.store(false, moRelease)
  mgr.threads[idx].epoch.store(ctx.epoch, moRelease)
  mgr.threads[idx].pinned.store(true, moRelease)
  # Publication fence: prevents the caller's subsequent loads of shared
  # state (the data this pin is meant to protect) from being reordered
  # before the `pinned=true` store becomes globally visible. Without
  # this, a reclaimer can observe `pinned=false` after we have already
  # loaded a pointer to a soon-to-be-retired object, and free the
  # object out from under us. Standard EBR publication barrier; matches
  # Crossbeam's pin path.
  threadFence(moSequentiallyConsistent)

  Pinned[MaxThreads](ctx)

proc unpin*[MaxThreads: static int](
    p: sink Pinned[MaxThreads]
): UnpinResult[MaxThreads] {.transition.} =
  ## Leave critical section. Returns Neutralized if signaled.
  runnableExamples:
    import debra
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    let pinned = unpinned(handle).pin()
    let res = pinned.unpin()
    case res.kind
    of uUnpinned:
      discard
    of uNeutralized:
      discard res.neutralized.acknowledge()
  let ctx = EpochGuardContext[MaxThreads](p)
  let mgr = ctx.handle.manager
  let idx = ctx.handle.idx

  mgr.threads[idx].pinned.store(false, moRelease)

  if mgr.threads[idx].neutralized.load(moAcquire):
    UnpinResult[MaxThreads] -> Neutralized[MaxThreads](ctx)
  else:
    UnpinResult[MaxThreads] -> Unpinned[MaxThreads](ctx)

proc acknowledge*[MaxThreads: static int](
    n: sink Neutralized[MaxThreads]
): Unpinned[MaxThreads] {.transition.} =
  ## Acknowledge neutralization. Required before re-pinning.
  ##
  ## See also: `unpin`_ (returns `Neutralized` when signaled), `pin`_.
  let ctx = EpochGuardContext[MaxThreads](n)
  ctx.handle.manager.threads[ctx.handle.idx].neutralized.store(false, moRelease)
  Unpinned[MaxThreads](EpochGuardContext[MaxThreads](handle: ctx.handle, epoch: 0))

func epoch*[MaxThreads: static int](p: Pinned[MaxThreads]): uint64 =
  ## Get the epoch this thread is pinned at.
  EpochGuardContext[MaxThreads](p).epoch

func handle*[MaxThreads: static int](p: Pinned[MaxThreads]): ThreadHandle[MaxThreads] =
  ## Get the thread handle.
  EpochGuardContext[MaxThreads](p).handle
