## nim-debra: DEBRA+ Safe Memory Reclamation
##
## This library provides typestate-enforced epoch-based reclamation
## with signal-based neutralization for lock-free data structures.

when not compileOption("threads"):
  {.error: "nim-debra requires --threads:on".}

import atomics
import ./debra/types
import ./debra/signal
import ./debra/typestates/registration
import ./debra/typestates/guard
import ./debra/typestates/reclaim
import ./debra/typestates/neutralize

export types
export signal.setGlobalManager, signal.installSignalHandler
export registration
export guard
export reclaim
export neutralize

proc registerThread*[MaxThreads: static int](
  manager: var DebraManager[MaxThreads]
): ThreadHandle[MaxThreads] {.raises: [DebraRegistrationError].} =
  ## Register current thread with the DEBRA manager.
  ##
  ## Must be called once per thread before any epoch operations.
  ## Raises DebraRegistrationError if max threads already registered.
  installSignalHandler()

  var op = start()

  while true:
    let slotCheck = op.findSlot(manager)
    case slotCheck.kind:
    of sThreadRegistrationFull:
      raise newException(DebraRegistrationError,
        "Maximum threads (" & $MaxThreads & ") already registered")
    of sThreadSlotFound:
      let claimResult = slotCheck.threadslotfound.tryClaim(manager)
      case claimResult.kind:
      of sThreadRegistered:
        return claimResult.threadregistered.extractHandle(manager)
      of sThreadUnregistered:
        op = claimResult.threadunregistered
        continue


proc neutralizeStalled*[MaxThreads: static int](
  manager: var DebraManager[MaxThreads],
  epochsBeforeNeutralize: uint64 = 2
): int =
  ## Signal all stalled threads. Returns number of signals sent.
  var op = neutralizeStart(manager, epochsBeforeNeutralize)
  op.scanAndSignal(manager)
  op.complete().extractSignalCount()


proc advance*[MaxThreads: static int](
  manager: var DebraManager[MaxThreads]
) {.inline.} =
  ## Advance the global epoch.
  discard manager.globalEpoch.fetchAdd(1'u64, moRelease)


proc currentEpoch*[MaxThreads: static int](
  manager: var DebraManager[MaxThreads]
): uint64 {.inline.} =
  ## Get current global epoch.
  manager.globalEpoch.load(moAcquire)
