# src/debra/signal.nim

## Signal handler for DEBRA+ thread neutralization.
##
## When a thread is stalled (hasn't advanced its epoch), other threads
## can send SIGUSR1 to force it to unpin, allowing reclamation to proceed.

import ./atomics
import std/posix

import ./constants
import ./types

var
  signalHandlerInstalled = false
  globalManagerPtr*: pointer = nil
    ## Set during manager initialization. Used by signal handler.

  # Layout of `DebraManager.threads` captured by `setGlobalManager` so
  # the SIGUSR1 handler can walk to the right per-thread slot without
  # knowing `MaxThreads` (the static parameter is not visible inside
  # the noconv async-signal handler). These are written under release
  # ordering before `globalManagerPtr` is published; the handler reads
  # them under acquire ordering after observing a non-nil
  # `globalManagerPtr`. Initial values are deliberately zero so that a
  # buggy signal-before-publish path cannot index into the manager:
  # `threadOffset = 0 + idx * 0 = 0`, which lands on the manager's
  # globalEpoch field (a harmless non-corruption read of an Atomic).
  threadsArrayOffsetBytes: Atomic[int]
  threadStateStrideBytes: Atomic[int]

# Offsets inside a single `ThreadState[N]` slot. These are independent
# of MaxThreads because `pinned` and `neutralized` come before the
# `cacheLinePad` field, and every preceding field has a fixed size.
# Computed once at compile time and asserted below. Expressed as
# templates rather than `const` so the magic `offsetOf` participates
# in the generic instantiation path cleanly.
template threadStatePinnedOffset(): int =
  offsetOf(ThreadState[DefaultMaxThreads], pinned)

template threadStateNeutralizedOffset(): int =
  offsetOf(ThreadState[DefaultMaxThreads], neutralized)

# Compile-time guard: the stride must be a clean multiple of the cache
# line, and the in-slot offsets must be byte-stable across MaxThreads
# choices. If anyone adds a field that shifts `pinned`/`neutralized`,
# or if the struct's size changes its multiple-of-CacheLineBytes
# property, the build fails here rather than corrupting memory at
# runtime.
static:
  assert sizeof(ThreadState[DefaultMaxThreads]) mod CacheLineBytes == 0,
    "ThreadState size (" & $sizeof(ThreadState[DefaultMaxThreads]) &
      ") must be a multiple of CacheLineBytes (" & $CacheLineBytes &
      ") -- adjust the `cacheLinePad` field in types.nim"
  # Spot-check that `pinned`/`neutralized` keep their byte positions
  # for at least two distinct MaxThreads sizes. If a future refactor
  # makes ThreadState's leading-field layout depend on MaxThreads, this
  # fails at compile time.
  assert offsetOf(ThreadState[4], pinned) == threadStatePinnedOffset(),
    "ThreadState.pinned offset must not depend on MaxThreads"
  assert offsetOf(ThreadState[4], neutralized) == threadStateNeutralizedOffset(),
    "ThreadState.neutralized offset must not depend on MaxThreads"

# Thread-local storage for thread index. Nim threadvars are
# zero-initialized, so a bare `int` cannot distinguish "unregistered" from
# "registered at slot 0". `threadLocalRegistered` is the explicit
# registered-bit; both fields must be consulted before treating
# `threadLocalIdx` as a real slot index. `registerThread` flips
# `threadLocalRegistered = true` after assigning a slot.
var threadLocalIdx* {.threadvar.}: int
var threadLocalRegistered* {.threadvar.}: bool
var threadLocalManager* {.threadvar.}: pointer
  ## Manager pointer the calling thread is registered with. Stored as raw
  ## `pointer` because the threadvar cannot carry the `MaxThreads` static
  ## parameter. Compared by identity in `reclaimStart(addr manager)` to
  ## reject the multi-manager hazard where a thread registered with manager
  ## A would otherwise have its `threadLocalIdx` interpreted against
  ## manager B's slot array.

proc neutralizationHandler(sig: cint) {.noconv.} =
  ## SIGUSR1 handler - force unpin if pinned, mark neutralized.
  ##
  ## This runs asynchronously when the OS delivers the signal.
  ## We use raw pointer arithmetic because we can't know MaxThreads
  ## at compile time in the signal handler context. Stride and header
  ## offset were captured by `setGlobalManager`; in-slot field offsets
  ## are compile-time constants derived from `offsetOf(ThreadState, ...)`.
  if threadLocalRegistered and globalManagerPtr != nil:
    let basePtr = cast[ptr UncheckedArray[byte]](globalManagerPtr)

    # Acquire-ordered reads pair with the release-ordered stores in
    # `setGlobalManager` so the stride/header values are guaranteed
    # visible once `globalManagerPtr` is non-nil.
    let headerSize = threadsArrayOffsetBytes.load(moAcquire)
    let stride = threadStateStrideBytes.load(moAcquire)
    if stride == 0:
      # `setGlobalManager` was never called with a typed manager.
      # Refuse to walk rather than scribble at offset 0.
      return

    let threadOffset = headerSize + threadLocalIdx * stride

    let pinnedPtr =
      cast[ptr Atomic[bool]](addr basePtr[threadOffset + threadStatePinnedOffset()])
    let neutralizedPtr = cast[ptr Atomic[bool]](addr basePtr[
      threadOffset + threadStateNeutralizedOffset()
    ])

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

proc setGlobalManager*[MaxThreads: static int](manager: ptr DebraManager[MaxThreads]) =
  ## Set the global manager pointer for the signal handler and capture
  ## the byte-stride information the handler needs to find each
  ## thread's slot.
  ##
  ## Must be called once after manager initialization, before any
  ## thread sends SIGUSR1. Safe to call repeatedly with the same
  ## manager; passing a different manager replaces the captured
  ## layout. Pass `nil` via the untyped overload below to clear the
  ## global manager.
  # Capture layout under release so the handler's acquire reads see
  # consistent stride+header before observing globalManagerPtr. We
  # compute the threads-array offset by pointer subtraction rather than
  # `offsetOf(DebraManager[MaxThreads], threads)` because the latter
  # form does not currently instantiate cleanly through Nim's generic
  # offsetOf path (the static MaxThreads parameter is not propagated
  # into the magic).
  let headerOffset = cast[int](addr manager.threads) - cast[int](manager)
  threadsArrayOffsetBytes.store(headerOffset, moRelease)
  threadStateStrideBytes.store(sizeof(ThreadState[MaxThreads]), moRelease)
  globalManagerPtr = cast[pointer](manager)

proc setGlobalManager*(manager: pointer) =
  ## Untyped overload, retained so callers (including tests) can clear
  ## the global manager by passing `nil`. Passing a non-nil raw pointer
  ## is unsupported because the handler needs the per-type stride;
  ## callers with a typed `ptr DebraManager[N]` should use the generic
  ## overload above.
  doAssert manager == nil,
    "setGlobalManager(pointer) only supports nil; use the generic overload " &
      "for typed managers so stride/header can be captured"
  threadStateStrideBytes.store(0, moRelease)
  threadsArrayOffsetBytes.store(0, moRelease)
  globalManagerPtr = nil
