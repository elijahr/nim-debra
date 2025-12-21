# src/debra/signal.nim

## Signal handler for DEBRA+ thread neutralization.
##
## When a thread is stalled (hasn't advanced its epoch), other threads
## can send SIGUSR1 to force it to unpin, allowing reclamation to proceed.

import atomics
import std/posix

import ./constants

var
  signalHandlerInstalled = false
  globalManagerPtr*: pointer = nil
    ## Set during manager initialization. Used by signal handler.

# Thread-local storage for thread index
var threadLocalIdx* {.threadvar.}: int

proc neutralizationHandler(sig: cint) {.noconv.} =
  ## SIGUSR1 handler - force unpin if pinned, mark neutralized.
  ##
  ## This runs asynchronously when the OS delivers the signal.
  ## We use raw pointer arithmetic because we can't know MaxThreads
  ## at compile time in the signal handler context.
  if threadLocalIdx >= 0 and globalManagerPtr != nil:
    let basePtr = cast[ptr UncheckedArray[byte]](globalManagerPtr)

    # Layout of DebraManager:
    # - globalEpoch: 64 bytes (aligned)
    # - activeThreadMask: 64 bytes (aligned)
    # - threads: array of ThreadState
    #
    # Layout of ThreadState (32 bytes):
    # - epoch: 8 bytes
    # - pinned: 8 bytes (padded)
    # - neutralized: 8 bytes (padded)
    # - osThreadId: 8 bytes
    const headerSize = 128 # Two cache lines
    const threadStateSize = 32

    let threadOffset = headerSize + threadLocalIdx * threadStateSize

    # Pinned is at offset 8 within ThreadState
    let pinnedPtr = cast[ptr Atomic[bool]](addr basePtr[threadOffset + 8])
    # Neutralized is at offset 16 within ThreadState
    let neutralizedPtr = cast[ptr Atomic[bool]](addr basePtr[threadOffset + 16])

    if pinnedPtr[].load(moAcquire):
      pinnedPtr[].store(false, moRelease)
      neutralizedPtr[].store(true, moRelease)

proc installSignalHandler*() =
  ## Install SIGUSR1 handler for DEBRA+ neutralization.
  ##
  ## Safe to call multiple times - subsequent calls are no-ops.
  ## Called automatically during first DebraManager initialization.
  if signalHandlerInstalled:
    return

  var sa: Sigaction
  sa.sa_handler = neutralizationHandler
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0 # No SA_RESTART - we want operations to be interrupted

  if sigaction(QuiescentSignal, sa, nil) == 0:
    signalHandlerInstalled = true

proc isSignalHandlerInstalled*(): bool =
  ## Check if signal handler has been installed.
  signalHandlerInstalled

proc setGlobalManager*(manager: pointer) =
  ## Set the global manager pointer for signal handler.
  ##
  ## Must be called once after manager initialization.
  globalManagerPtr = manager
