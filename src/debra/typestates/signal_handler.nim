## SignalHandler typestate.
##
## Ensures signal handler is installed before DEBRA operations.
##
## On POSIX this installs a real SIGUSR1 handler (placeholder — the
## production handler lives in `debra/signal.nim`). On Windows the
## "install" step is a no-op because the neutralization protocol uses
## SuspendThread/ResumeThread directly; the typestate transition is
## retained for API parity so callers compile unchanged.

import typestates

when not defined(windows):
  import std/posix
  import ../constants

type
  SignalHandlerContext* = object of RootObj
    installed: bool

  HandlerUninstalled* = distinct SignalHandlerContext
  HandlerInstalled* = distinct SignalHandlerContext

typestate SignalHandlerContext:
  inheritsFromRootObj = true
  opaqueStates = true
  states HandlerUninstalled, HandlerInstalled
  initial:
    HandlerUninstalled
  terminal:
    HandlerInstalled
  transitions:
    HandlerUninstalled -> HandlerInstalled

when not defined(windows):
  proc neutralizationHandler(sig: cint) {.noconv.} =
    ## SIGUSR1 handler - placeholder, real impl in signal.nim
    discard

proc initSignalHandler*(): HandlerUninstalled =
  ## Create uninstalled signal handler context.
  HandlerUninstalled(SignalHandlerContext(installed: false))

proc install*(h: HandlerUninstalled): HandlerInstalled {.transition.} =
  ## Install SIGUSR1 handler for DEBRA+ neutralization.
  ##
  ## On Windows this is a no-op (no async handler is needed); the
  ## transition still flips `installed = true` for API parity.
  when not defined(windows):
    var sa: Sigaction
    sa.sa_handler = neutralizationHandler
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = 0
    discard sigaction(QuiescentSignal, sa, nil)
  result = HandlerInstalled(SignalHandlerContext(installed: true))

func isInstalled*(h: HandlerInstalled): bool {.notATransition.} =
  ## Check if handler is installed.
  h.SignalHandlerContext.installed
