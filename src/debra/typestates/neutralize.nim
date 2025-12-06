# src/debra/typestates/neutralize.nim

## Neutralization typestate.
##
## Enforces correct DEBRA+ signal-based neutralization sequence:
## Start -> Scanning -> Complete
##
## Key invariant: Only signal threads that are stalled (behind current epoch).

import atomics
import std/posix

import ../types
import ../constants

type
  NeutralizeStart*[MaxThreads: static int] = object
    ## Begin neutralization of stalled threads.

  NeutralizeScanning*[MaxThreads: static int] = object
    ## Scanning thread states.
    globalEpoch*: uint64
    threshold*: uint64
      ## Threads with epoch below this get signaled.
    signalsSent*: int

  NeutralizeComplete*[MaxThreads: static int] = object
    ## Finished sending signals.
    signalsSent*: int


proc neutralizeStart*[MaxThreads: static int](
  manager: var DebraManager[MaxThreads],
  epochsBeforeNeutralize: uint64 = 2
): NeutralizeScanning[MaxThreads] {.inline.} =
  ## Begin neutralization. Threads more than `epochsBeforeNeutralize` behind get signaled.
  let globalEpoch = manager.globalEpoch.load(moAcquire)
  let threshold = if globalEpoch > epochsBeforeNeutralize:
    globalEpoch - epochsBeforeNeutralize
  else:
    0'u64

  NeutralizeScanning[MaxThreads](
    globalEpoch: globalEpoch,
    threshold: threshold,
    signalsSent: 0
  )


proc scanAndSignal*[MaxThreads: static int](
  op: var NeutralizeScanning[MaxThreads],
  manager: var DebraManager[MaxThreads]
) {.inline.} =
  ## Scan all threads and signal those that are stalled.
  ## NOT a transition - modifies op in place.
  let activeMask = manager.activeThreadMask.load(moAcquire)
  let currentTid = getThreadId().Pid

  for i in 0..<MaxThreads:
    if (activeMask and (1'u64 shl i)) != 0:
      # Thread is registered
      if manager.threads[i].pinned.load(moAcquire):
        # Thread is pinned
        let threadEpoch = manager.threads[i].epoch.load(moAcquire)
        if threadEpoch < op.threshold:
          # Thread is stalled - send signal
          let tid = manager.threads[i].osThreadId.load(moAcquire)
          if tid != Pid(0) and tid != currentTid:
            # Don't signal ourselves
            discard pthread_kill(tid, QuiescentSignal)
            inc op.signalsSent


proc complete*[MaxThreads: static int](
  op: NeutralizeScanning[MaxThreads]
): NeutralizeComplete[MaxThreads] {.inline.} =
  NeutralizeComplete[MaxThreads](signalsSent: op.signalsSent)


proc extractSignalCount*[MaxThreads: static int](
  op: NeutralizeComplete[MaxThreads]
): int {.inline.} =
  op.signalsSent
