## Neutralize typestate for DEBRA+ neutralization signaling.
##
## Ensures proper sequence: ScanStart -> Scanning -> ScanComplete
##
## When the epoch needs to advance, scan all threads and send SIGUSR1
## to pinned threads that are stalled (behind globalEpoch by threshold).

import atomics
import typestates

import ../types
import ../constants
import ../thread_id

type
  NeutralizeContext*[MaxThreads: static int] = object of RootObj
    manager*: ptr DebraManager[MaxThreads]
    globalEpoch*: uint64
    threshold*: uint64
    signalsSent*: int

  ScanStart*[MaxThreads: static int] = distinct NeutralizeContext[MaxThreads]
  Scanning*[MaxThreads: static int] = distinct NeutralizeContext[MaxThreads]
  ScanComplete*[MaxThreads: static int] = distinct NeutralizeContext[MaxThreads]

typestate NeutralizeContext[MaxThreads: static int]:
  inheritsFromRootObj = true
  states ScanStart[MaxThreads], Scanning[MaxThreads], ScanComplete[MaxThreads]
  transitions:
    ScanStart[MaxThreads] -> Scanning[MaxThreads]
    Scanning[MaxThreads] -> ScanComplete[MaxThreads]


proc scanStart*[MaxThreads: static int](
  mgr: ptr DebraManager[MaxThreads]
): ScanStart[MaxThreads] =
  ## Begin neutralization scan.
  ScanStart[MaxThreads](NeutralizeContext[MaxThreads](
    manager: mgr,
    globalEpoch: 0,
    threshold: 0,
    signalsSent: 0
  ))


proc loadEpoch*[MaxThreads: static int](
  s: ScanStart[MaxThreads],
  epochsBeforeNeutralize: uint64 = 2
): Scanning[MaxThreads] {.transition.} =
  ## Load global epoch and compute threshold for stalled threads.
  ## Threads with epoch < (globalEpoch - epochsBeforeNeutralize) get signaled.
  var ctx = NeutralizeContext[MaxThreads](s)
  ctx.globalEpoch = ctx.manager.globalEpoch.load(moAcquire)

  ctx.threshold = if ctx.globalEpoch > epochsBeforeNeutralize:
    ctx.globalEpoch - epochsBeforeNeutralize
  else:
    0'u64

  result = Scanning[MaxThreads](ctx)


func globalEpoch*[MaxThreads: static int](s: Scanning[MaxThreads]): uint64 =
  ## Get the global epoch loaded during scan start.
  NeutralizeContext[MaxThreads](s).globalEpoch


func threshold*[MaxThreads: static int](s: Scanning[MaxThreads]): uint64 =
  ## Get the epoch threshold for neutralization.
  NeutralizeContext[MaxThreads](s).threshold


proc scanAndSignal*[MaxThreads: static int](
  s: Scanning[MaxThreads]
): ScanComplete[MaxThreads] {.transition.} =
  ## Scan all registered threads and send SIGUSR1 to stalled pinned threads.
  ## Returns count of signals sent.
  var ctx = NeutralizeContext[MaxThreads](s)
  let activeMask = ctx.manager.activeThreadMask.load(moAcquire)
  let currentTid = currentThreadId()

  for i in 0..<MaxThreads:
    if (activeMask and (1'u64 shl i)) != 0:
      # Thread is registered
      if ctx.manager.threads[i].pinned.load(moAcquire):
        # Thread is pinned
        let threadEpoch = ctx.manager.threads[i].epoch.load(moAcquire)
        if threadEpoch < ctx.threshold:
          # Thread is stalled - send signal
          let tid = ctx.manager.threads[i].threadId.load(moAcquire)
          if tid.isValid and tid != currentTid:
            # Don't signal ourselves or unset threads
            discard tid.sendSignal(QuiescentSignal)
            inc ctx.signalsSent

  result = ScanComplete[MaxThreads](ctx)


func signalsSent*[MaxThreads: static int](c: ScanComplete[MaxThreads]): int =
  ## Get number of signals sent during scan.
  NeutralizeContext[MaxThreads](c).signalsSent


func extractSignalCount*[MaxThreads: static int](
  c: ScanComplete[MaxThreads]
): int =
  ## Extract the count of signals sent. Terminal operation.
  NeutralizeContext[MaxThreads](c).signalsSent
