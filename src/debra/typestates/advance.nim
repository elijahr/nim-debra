## EpochAdvance typestate for advancing the global epoch.
##
## Ensures atomic increment of the global epoch counter.
##
## The typestate carries a `CC: static PinScopeCardinality = ccSingle`
## param so that ccMulti managers built by `initDebraManager[N, ccMulti]()`
## can flow through this surface. The advance ALGORITHM is intentionally
## CC-agnostic (pure atomic epoch arithmetic, no cardinality-dependent
## branching), but the type system has to thread `CC` to accept a
## `ptr DebraManager[MT, CC]` field for both cardinalities. The default
## `ccSingle` preserves the 0.7.x-style call shape unchanged.

import ../atomics
import typestates

import ../types

type
  AdvanceContext*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] = object of RootObj
    manager*: ptr DebraManager[MaxThreads, CC]
    oldEpoch*: uint64
    newEpoch*: uint64

  Current*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct AdvanceContext[MaxThreads, CC]
  Advancing*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct AdvanceContext[MaxThreads, CC]
  Advanced*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct AdvanceContext[MaxThreads, CC]

typestate AdvanceContext[MaxThreads: static int, CC: static PinScopeCardinality]:
  inheritsFromRootObj = true
  opaqueStates = true
  defaults:
    CC:
      ccSingle
  states Current[MaxThreads, CC], Advancing[MaxThreads, CC], Advanced[MaxThreads, CC]
  initial:
    Current[MaxThreads, CC]
  terminal:
    Advanced[MaxThreads, CC]
  transitions:
    Current[MaxThreads, CC] -> Advancing[MaxThreads, CC]
    Advancing[MaxThreads, CC] -> Advanced[MaxThreads, CC]

proc advanceCurrent*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    mgr: ptr DebraManager[MaxThreads, CC]
): Current[MaxThreads, CC] =
  ## Create epoch advance context.
  Current[MaxThreads, CC](
    AdvanceContext[MaxThreads, CC](manager: mgr, oldEpoch: 0, newEpoch: 0)
  )

proc advance*[MaxThreads: static int, CC: static PinScopeCardinality](
    c: sink Current[MaxThreads, CC]
): Advancing[MaxThreads, CC] {.transition.} =
  ## Begin advancing the global epoch.
  let ctx = AdvanceContext[MaxThreads, CC](c)
  Advancing[MaxThreads, CC](
    AdvanceContext[MaxThreads, CC](manager: ctx.manager, oldEpoch: 0, newEpoch: 0)
  )

proc complete*[MaxThreads: static int, CC: static PinScopeCardinality](
    a: sink Advancing[MaxThreads, CC]
): Advanced[MaxThreads, CC] {.transition.} =
  ## Complete epoch advance by atomically incrementing globalEpoch.
  let ctx = AdvanceContext[MaxThreads, CC](a)

  # Atomically increment the global epoch using fetchAdd
  let oldEpoch = ctx.manager.globalEpoch.fetchAdd(1'u64, moRelease)
  let newEpoch = oldEpoch + 1'u64

  Advanced[MaxThreads, CC](
    AdvanceContext[MaxThreads, CC](
      manager: ctx.manager, oldEpoch: oldEpoch, newEpoch: newEpoch
    )
  )

func newEpoch*[MaxThreads: static int, CC: static PinScopeCardinality](
    a: Advanced[MaxThreads, CC]
): uint64 {.notATransition.} =
  ## Get the new epoch value after advancement.
  AdvanceContext[MaxThreads, CC](a).newEpoch

func oldEpoch*[MaxThreads: static int, CC: static PinScopeCardinality](
    a: Advanced[MaxThreads, CC]
): uint64 {.notATransition.} =
  ## Get the old epoch value before advancement.
  AdvanceContext[MaxThreads, CC](a).oldEpoch
