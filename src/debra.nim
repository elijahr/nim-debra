## nim-debra: DEBRA+ Safe Memory Reclamation
##
## This library provides typestate-enforced epoch-based reclamation
## with signal-based neutralization for lock-free data structures.

when not compileOption("threads"):
  {.error: "nim-debra requires --threads:on".}

import ./debra/types
import ./debra/signal
import ./debra/typestates/registration
import ./debra/typestates/guard

export types
export signal.setGlobalManager, signal.installSignalHandler
export registration
export guard

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
