## EpochAdvance typestate for advancing the global epoch.
##
## Ensures atomic increment of the global epoch counter.

import atomics
import typestates

import ../types

type
  AdvanceContext*[MaxThreads: static int] = object of RootObj
    manager*: ptr DebraManager[MaxThreads]
    oldEpoch*: uint64
    newEpoch*: uint64

  Current*[MaxThreads: static int] = distinct AdvanceContext[MaxThreads]
  Advancing*[MaxThreads: static int] = distinct AdvanceContext[MaxThreads]
  Advanced*[MaxThreads: static int] = distinct AdvanceContext[MaxThreads]

typestate AdvanceContext[MaxThreads: static int]:
  inheritsFromRootObj = true
  states Current[MaxThreads], Advancing[MaxThreads], Advanced[MaxThreads]
  transitions:
    Current[MaxThreads] -> Advancing[MaxThreads]
    Advancing[MaxThreads] -> Advanced[MaxThreads]

proc advanceCurrent*[MaxThreads: static int](
    mgr: ptr DebraManager[MaxThreads]
): Current[MaxThreads] =
  ## Create epoch advance context.
  Current[MaxThreads](
    AdvanceContext[MaxThreads](manager: mgr, oldEpoch: 0, newEpoch: 0)
  )

proc advance*[MaxThreads: static int](
    c: sink Current[MaxThreads]
): Advancing[MaxThreads] {.transition.} =
  ## Begin advancing the global epoch.
  let ctx = AdvanceContext[MaxThreads](c)
  Advancing[MaxThreads](
    AdvanceContext[MaxThreads](manager: ctx.manager, oldEpoch: 0, newEpoch: 0)
  )

proc complete*[MaxThreads: static int](
    a: sink Advancing[MaxThreads]
): Advanced[MaxThreads] {.transition.} =
  ## Complete epoch advance by atomically incrementing globalEpoch.
  let ctx = AdvanceContext[MaxThreads](a)

  # Atomically increment the global epoch using fetchAdd
  let oldEpoch = ctx.manager.globalEpoch.fetchAdd(1'u64, moRelease)
  let newEpoch = oldEpoch + 1'u64

  Advanced[MaxThreads](
    AdvanceContext[MaxThreads](
      manager: ctx.manager, oldEpoch: oldEpoch, newEpoch: newEpoch
    )
  )

func newEpoch*[MaxThreads: static int](a: Advanced[MaxThreads]): uint64 =
  ## Get the new epoch value after advancement.
  AdvanceContext[MaxThreads](a).newEpoch

func oldEpoch*[MaxThreads: static int](a: Advanced[MaxThreads]): uint64 =
  ## Get the old epoch value before advancement.
  AdvanceContext[MaxThreads](a).oldEpoch
