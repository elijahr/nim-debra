## Neutralize typestate for DEBRA+ neutralization signaling.
##
## Ensures proper sequence: ScanStart -> Scanning -> ScanComplete
##
## When the epoch needs to advance, scan all threads and send SIGUSR1
## to pinned threads that are stalled (behind globalEpoch by threshold).

import ../atomics
import typestates

import ../types
import ../constants
import ../thread_id
import ../signal

type
  NeutralizeContext*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] = object of RootObj
    manager*: ptr DebraManager[MaxThreads, CC]
    globalEpoch*: uint64
    threshold*: uint64
    signalsSent*: int

  ScanStart*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct NeutralizeContext[MaxThreads, CC]
  Scanning*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct NeutralizeContext[MaxThreads, CC]
  ScanComplete*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle] =
    distinct NeutralizeContext[MaxThreads, CC]

typestate NeutralizeContext[MaxThreads: static int, CC: static PinScopeCardinality]:
  inheritsFromRootObj = true
  opaqueStates = true
  defaults:
    CC:
      ccSingle
  states ScanStart[MaxThreads, CC],
    Scanning[MaxThreads, CC], ScanComplete[MaxThreads, CC]
  initial:
    ScanStart[MaxThreads, CC]
  terminal:
    ScanComplete[MaxThreads, CC]
  transitions:
    ScanStart[MaxThreads, CC] -> Scanning[MaxThreads, CC]
    Scanning[MaxThreads, CC] -> ScanComplete[MaxThreads, CC]

proc scanStart*[MaxThreads: static int, CC: static PinScopeCardinality = ccSingle](
    mgr: ptr DebraManager[MaxThreads, CC]
): ScanStart[MaxThreads, CC] =
  ## Begin neutralization scan.
  ScanStart[MaxThreads, CC](
    NeutralizeContext[MaxThreads, CC](
      manager: mgr, globalEpoch: 0, threshold: 0, signalsSent: 0
    )
  )

proc loadEpoch*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: ScanStart[MaxThreads, CC], epochsBeforeNeutralize: uint64 = 2
): Scanning[MaxThreads, CC] {.transition.} =
  ## Load global epoch and compute threshold for stalled threads.
  ## Threads with epoch < (globalEpoch - epochsBeforeNeutralize) get signaled.
  var ctx = NeutralizeContext[MaxThreads, CC](s)
  ctx.globalEpoch = ctx.manager.globalEpoch.load(moAcquire)

  ctx.threshold =
    if ctx.globalEpoch > epochsBeforeNeutralize:
      ctx.globalEpoch - epochsBeforeNeutralize
    else:
      0'u64

  result = Scanning[MaxThreads, CC](ctx)

func globalEpoch*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Scanning[MaxThreads, CC]
): uint64 {.notATransition.} =
  ## Get the global epoch loaded during scan start.
  NeutralizeContext[MaxThreads, CC](s).globalEpoch

func threshold*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Scanning[MaxThreads, CC]
): uint64 {.notATransition.} =
  ## Get the epoch threshold for neutralization.
  NeutralizeContext[MaxThreads, CC](s).threshold

proc scanAndSignal*[MaxThreads: static int, CC: static PinScopeCardinality](
    s: Scanning[MaxThreads, CC]
): ScanComplete[MaxThreads, CC] {.transition.} =
  ## Scan all registered threads and send SIGUSR1 to stalled pinned threads.
  ## Returns count of signals sent.
  var ctx = NeutralizeContext[MaxThreads, CC](s)
  let activeMask = ctx.manager.activeThreadMask.load(moAcquire)
  let currentTid = currentThreadId()
  # KNOWN_GAP (Windows): on Windows `currentThreadId()` allocates a fresh
  # duplicated handle via `DuplicateHandle`; the handle leaks per scan
  # iteration. An earlier `defer closeThreadId(currentTid)` was reverted
  # alongside the unregister-side close (898c160 -> v0.10.0 cycle-22)
  # because the paired unregister-side close introduced a Windows
  # use-after-close crash in `examples/reclamation_background`. The
  # scanner-side close on its own is safe (the handle is scanner-local),
  # but is reverted in tandem so the documented leak is uniform until
  # v0.11.0 introduces a deferred-close mechanism. On POSIX this is a
  # non-issue: `ThreadId` is a `pthread_t`, no kernel resource attached.

  for i in 0 ..< MaxThreads:
    if (activeMask and (1'u64 shl i)) != 0:
      # Thread is registered
      if ctx.manager.threads[i].pinned.load(moAcquire):
        # Thread is pinned
        let threadEpoch = ctx.manager.threads[i].epoch.load(moAcquire)
        if threadEpoch < ctx.threshold:
          # Thread is stalled - send signal
          let tid = ctx.manager.threads[i].threadId.load(moAcquire)
          if tid.isValid and tid != currentTid:
            # Don't signal ourselves or unset threads.
            # `neutralizeRemoteSlot` abstracts the platform difference:
            # POSIX delivers SIGUSR1 (handler reads target's
            # `threadLocalIdx`); Windows suspends the target, flips the
            # slot using the explicit `i` argument, then resumes.
            neutralizeRemoteSlot(tid, i)
            inc ctx.signalsSent

  result = ScanComplete[MaxThreads, CC](ctx)

func signalsSent*[MaxThreads: static int, CC: static PinScopeCardinality](
    c: ScanComplete[MaxThreads, CC]
): int {.notATransition.} =
  ## Get number of signals sent during scan.
  NeutralizeContext[MaxThreads, CC](c).signalsSent

func extractSignalCount*[MaxThreads: static int, CC: static PinScopeCardinality](
    c: ScanComplete[MaxThreads, CC]
): int {.notATransition.} =
  ## Extract the count of signals sent. Terminal operation.
  NeutralizeContext[MaxThreads, CC](c).signalsSent
