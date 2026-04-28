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
  globalManagerPtr*: Atomic[pointer]
    ## Set during manager initialization. Used by signal handler.
    ## Stored as `Atomic[pointer]` (rather than a plain `pointer`) so the
    ## publish path in `setGlobalManager` can use `moRelease` and the
    ## consumer in the signal handler can use `moAcquire`. Without this,
    ## the stride/header release stores would not synchronize with the
    ## handler's reads through any defined happens-before edge — a
    ## handler could observe the new pointer paired with stale stride or
    ## header values from a previous manager.

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

# Compile-time guard: pin the absolute byte offsets of `pinned` and
# `neutralized` inside `ThreadState`. The signal handler cannot see
# `MaxThreads`, so it relies on these offsets being stable values. If
# anyone reorders `ThreadState` fields, changes the leading `epoch`'s
# size, or otherwise shifts `pinned`/`neutralized`, the build fails
# here rather than corrupting memory at runtime. The values 8 and 16
# correspond to the current layout: `epoch` (8 bytes, align 8) at 0,
# `pinned` (Atomic[bool], align 8) at 8, `neutralized` (Atomic[bool],
# align 8) at 16. If a legitimate reorder is needed, update these
# constants together with the layout — and re-read this comment to
# understand why the handler depends on them.
#
# The stride must also remain a clean multiple of the cache line so
# adjacent `ThreadState` slots in `DebraManager.threads` do not
# false-share. The third assert spot-checks that the offsets are
# stable across distinct `MaxThreads` instantiations, which is the
# load-bearing property the handler needs (the handler is compiled
# without knowledge of `MaxThreads`, so any layout drift across
# instantiations would corrupt the walk).
static:
  assert threadStatePinnedOffset() == 8,
    "ThreadState.pinned must be at byte offset 8 (got " & $threadStatePinnedOffset() &
      "); the signal handler depends on this absolute offset. " &
      "If you intentionally changed the layout, update this assert " &
      "and the matching one for `neutralized`."
  assert threadStateNeutralizedOffset() == 16,
    "ThreadState.neutralized must be at byte offset 16 (got " &
      $threadStateNeutralizedOffset() &
      "); the signal handler depends on this absolute offset. " &
      "If you intentionally changed the layout, update this assert " &
      "and the matching one for `pinned`."
  assert sizeof(ThreadState[DefaultMaxThreads]) mod CacheLineBytes == 0,
    "ThreadState size (" & $sizeof(ThreadState[DefaultMaxThreads]) &
      ") must be a multiple of CacheLineBytes (" & $CacheLineBytes &
      ") -- adjust the `cacheLinePad` field in types.nim"
  # Cross-MaxThreads stability check: even with the absolute-offset
  # asserts above, verify the offsets do not drift between
  # instantiations (e.g., if a future generic field were added that
  # depended on MaxThreads).
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
  if not threadLocalRegistered:
    return

  # Load the manager pointer FIRST under acquire so it pairs with the
  # release store in `setGlobalManager`. The release/acquire edge
  # guarantees that stride and header values stored *before* the
  # pointer are visible *after* the pointer is observed non-nil. If we
  # loaded stride/header first, a reader could observe a fresh
  # `globalManagerPtr` paired with stale stride/header from a previous
  # manager (or vice versa) — exactly the publish-ordering hazard the
  # surrounding comments claim to prevent.
  let mgrPtr = globalManagerPtr.load(moAcquire)
  if mgrPtr != nil:
    let basePtr = cast[ptr UncheckedArray[byte]](mgrPtr)

    # Acquire-ordered reads here are technically redundant given the
    # acquire on `mgrPtr` above (the release store on `mgrPtr` happens
    # after the release stores on stride/header, so observing the
    # pointer transitively makes the prior stores visible). They are
    # retained for clarity and as defense-in-depth: if anyone reorders
    # the publish path in `setGlobalManager`, these acquires keep the
    # handler correct on its own merits.
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
  ##
  ## **Race constraint:** This routine MUST NOT race with signal
  ## delivery. Either call it before any thread is registered, or fully
  ## quiesce all threads (no in-flight or pending SIGUSR1) before
  ## replacing the manager. The three atomic stores (header, stride,
  ## pointer) are not a single transaction: a signal arriving partway
  ## through could observe stride/header from one manager paired with
  ## the pointer from another, and if the two managers were
  ## instantiated with different `MaxThreads` their layouts differ.
  ## The release/acquire edge below makes the *intra-call* publish
  ## order consistent (a reader who sees the new pointer also sees the
  ## new stride/header), but it does not make the call as a whole
  ## atomic with respect to a concurrent reader, and it does not
  ## protect against a reader pairing the *new* pointer with the *old*
  ## stride that was just overwritten.
  # Capture layout under release so the handler's acquire reads see
  # consistent stride+header before observing globalManagerPtr. The
  # publish order matters: stride/header MUST be stored before the
  # pointer, so a handler that loads the pointer with acquire and
  # observes the new value is guaranteed to see the matching new
  # stride/header. We compute the threads-array offset by pointer
  # subtraction rather than `offsetOf(DebraManager[MaxThreads],
  # threads)` because the latter form does not currently instantiate
  # cleanly through Nim's generic offsetOf path (the static MaxThreads
  # parameter is not propagated into the magic).
  let headerOffset = cast[int](addr manager.threads) - cast[int](manager)
  threadsArrayOffsetBytes.store(headerOffset, moRelease)
  threadStateStrideBytes.store(sizeof(ThreadState[MaxThreads]), moRelease)
  # Pointer published LAST under release. A handler that observes
  # this non-nil pointer (under acquire) is guaranteed to see the
  # stride/header writes above.
  globalManagerPtr.store(cast[pointer](manager), moRelease)

proc setGlobalManager*(manager: pointer) =
  ## Untyped overload, retained so callers (including tests) can clear
  ## the global manager by passing `nil`. Passing a non-nil raw pointer
  ## is unsupported because the handler needs the per-type stride;
  ## callers with a typed `ptr DebraManager[N]` should use the generic
  ## overload above.
  ##
  ## **Race constraint:** Same as the typed overload — must not race
  ## with signal delivery. Quiesce all registered threads before
  ## clearing the manager.
  doAssert manager == nil,
    "setGlobalManager(pointer) only supports nil; use the generic overload " &
      "for typed managers so stride/header can be captured"
  # Clear the pointer FIRST under release so any handler that loads
  # it under acquire and sees nil bails out before reading stride.
  # Then zero stride/header. This also matches the publish order in
  # the typed overload (pointer is the synchronizing edge).
  globalManagerPtr.store(nil, moRelease)
  threadStateStrideBytes.store(0, moRelease)
  threadsArrayOffsetBytes.store(0, moRelease)
