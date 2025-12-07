## nim-debra: DEBRA+ Safe Memory Reclamation
##
## This library provides typestate-enforced epoch-based reclamation
## with signal-based neutralization for lock-free data structures.

when not compileOption("threads"):
  {.error: "nim-debra requires --threads:on".}

import atomics
import ./debra/types
import ./debra/signal
import ./debra/limbo
import ./debra/typestates/signal_handler
import ./debra/typestates/manager
import ./debra/typestates/registration
import ./debra/typestates/guard
import ./debra/typestates/retire
import ./debra/typestates/reclaim
import ./debra/typestates/neutralize
import ./debra/typestates/advance
import ./debra/typestates/slot

export types
export signal.setGlobalManager, signal.installSignalHandler
export limbo
export signal_handler
export manager
export registration
export guard
export retire
export reclaim
export neutralize
export advance
export slot

proc registerThread*[MaxThreads: static int](
  manager: var DebraManager[MaxThreads]
): ThreadHandle[MaxThreads] {.raises: [DebraRegistrationError].} =
  ## Register current thread with the DEBRA manager.
  ##
  ## Must be called once per thread before any epoch operations.
  ## Raises DebraRegistrationError if max threads already registered.
  installSignalHandler()

  let u = unregistered(addr manager)
  let result = u.register()
  case result.kind:
  of rRegistered:
    return result.registered.getHandle()
  of rRegistrationFull:
    raise newException(DebraRegistrationError,
      "Maximum threads (" & $MaxThreads & ") already registered")


proc neutralizeStalled*[MaxThreads: static int](
  manager: var DebraManager[MaxThreads],
  epochsBeforeNeutralize: uint64 = 2
): int =
  ## Signal all stalled threads. Returns number of signals sent.
  let op = scanStart(addr manager)
  let scanning = op.loadEpoch(epochsBeforeNeutralize)
  let complete = scanning.scanAndSignal()
  complete.extractSignalCount()


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
