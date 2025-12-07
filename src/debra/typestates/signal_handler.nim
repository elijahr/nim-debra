## SignalHandler typestate.
##
## Ensures signal handler is installed before DEBRA operations.

import std/posix
import typestates

import ../constants

type
  SignalHandlerContext* = object
    installed: bool

  HandlerUninstalled* = distinct SignalHandlerContext
  HandlerInstalled* = distinct SignalHandlerContext

typestate SignalHandlerContext:
  states HandlerUninstalled, HandlerInstalled
  transitions:
    HandlerUninstalled -> HandlerInstalled


proc neutralizationHandler(sig: cint) {.noconv.} =
  ## SIGUSR1 handler - placeholder, real impl in signal.nim
  discard


proc initSignalHandler*(): HandlerUninstalled =
  ## Create uninstalled signal handler context.
  HandlerUninstalled(SignalHandlerContext(installed: false))


proc install*(h: HandlerUninstalled): HandlerInstalled {.transition.} =
  ## Install SIGUSR1 handler for DEBRA+ neutralization.
  var sa: Sigaction
  sa.sa_handler = neutralizationHandler
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(QuiescentSignal, sa, nil)
  result = HandlerInstalled(SignalHandlerContext(installed: true))


func isInstalled*(h: HandlerInstalled): bool =
  ## Check if handler is installed.
  h.SignalHandlerContext.installed
