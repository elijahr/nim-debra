## nim-debra: DEBRA+ Safe Memory Reclamation
##
## This library provides typestate-enforced epoch-based reclamation
## with signal-based neutralization for lock-free data structures.

when not compileOption("threads"):
  {.error: "nim-debra requires --threads:on".}

import ./debra/atomics
import ./debra/types
import ./debra/signal
import ./debra/limbo
import ./debra/thread_id
import ./debra/typestates/signal_handler
import ./debra/typestates/manager
import ./debra/typestates/registration
import ./debra/typestates/guard
import ./debra/typestates/retire
import ./debra/typestates/reclaim
import ./debra/typestates/neutralize
import ./debra/typestates/advance
import ./debra/typestates/slot
import ./debra/refptr
import ./debra/convenience

export types
export signal.setGlobalManager, signal.installSignalHandler
export limbo
export thread_id
export signal_handler
export manager
export registration
export guard
export retire
export reclaim
export neutralize
export advance
export slot
export refptr
export convenience

proc registerThread*[MaxThreads: static int](
    manager: var DebraManager[MaxThreads]
): ThreadHandle[MaxThreads] {.raises: [DebraRegistrationError].} =
  ## Register current thread with the DEBRA manager.
  ##
  ## Must be called once per thread before any epoch operations.
  ## Raises DebraRegistrationError if max threads already registered.
  installSignalHandler()

  let u = unregistered(addr manager)
  let regResult = u.register()
  case regResult.kind
  of rRegistered:
    return regResult.registered.getHandle()
  of rRegistrationFull:
    raise newException(
      DebraRegistrationError, "Maximum threads (" & $MaxThreads & ") already registered"
    )

proc neutralizeStalled*[MaxThreads: static int](
    manager: var DebraManager[MaxThreads], epochsBeforeNeutralize: uint64 = 2
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

proc bindClient*[MaxThreads: static int](
    manager: var DebraManager[MaxThreads]
) {.inline.} =
  ## Register a client (e.g. a lock-free data structure) as bound to
  ## this manager. Increments `boundClients` by 1.
  ##
  ## Lock-free libraries built on nim-debra should call `bindClient` in
  ## their constructor and `unbindClient` in their destructor. The
  ## manager's destructor asserts the count is zero, so a non-zero
  ## count at teardown means a client outlived its manager: the client
  ## would continue calling into freed manager state.
  discard manager.boundClients.fetchAdd(1, moAcquireRelease)

proc unbindClient*[MaxThreads: static int](
    manager: var DebraManager[MaxThreads]
) {.inline.} =
  ## Unregister a client previously bound via `bindClient`. Decrements
  ## `boundClients` by 1. See `bindClient` for usage.
  ##
  ## Asserts the previous count was positive: an underflow indicates an
  ## unbalanced unbind (e.g. double-destroy of a client) and is caught
  ## here with a precise stack trace, rather than later as a non-zero
  ## value seen by the manager destructor.
  let prev = manager.boundClients.fetchSub(1, moAcquireRelease)
  doAssert prev > 0,
    "unbindClient: boundClients underflow (was " & $prev &
      ", expected > 0); unbalanced bindClient/unbindClient"

proc clientCount*[MaxThreads: static int](
    manager: var DebraManager[MaxThreads]
): int {.inline.} =
  ## Number of clients currently bound to this manager. Relaxed load,
  ## suitable for inspection and tests; not synchronized against
  ## concurrent `bindClient` / `unbindClient`.
  manager.boundClients.load(moRelaxed)
