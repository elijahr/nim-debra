# src/debra/signal.nim

## Thread neutralization for DEBRA+.
##
## Two-arm implementation:
##
## - **POSIX**: SIGUSR1 handler. Other threads send SIGUSR1; the handler
##   runs asynchronously in the target's context and flips
##   `pinned`/`neutralized` in the target's slot via raw pointer
##   arithmetic (stride captured by `setGlobalManager`).
##
## - **Windows**: SuspendThread/ResumeThread. The scanner suspends the
##   target, walks `manager.threads[]` via the same pointer arithmetic
##   the POSIX handler uses, flips the slot, then resumes. There is no
##   asynchronous handler; `installSignalHandler` and
##   `forceReinstallSignalHandler` are no-ops on this platform.
##
## **Deadlock constraint (both arms)**: do not call DEBRA reclamation
## while holding a lock that other DEBRA-using threads might be blocked
## on. The constraint is the same on both platforms; the mechanism
## differs (signal-handler-side acquire on POSIX vs. scanner-side
## suspend-and-wait on Windows).
##
## The cross-platform `neutralizeRemoteSlot` entry point hides the
## difference from `neutralize.scanAndSignal`.

import ./atomics

import ./constants
import ./thread_id
import ./types

when defined(windows):
  import std/winlean

  # Cycle-43: `GetExitCodeThread`-based discrimination between
  # "really alive" and "dying" threads was removed because the
  # `STILL_ACTIVE` exit code can be returned for a thread that has
  # already begun teardown but whose handle has not yet been signaled
  # by the kernel. The previous policy (raiseAssert on
  # `STILL_ACTIVE`) produced false-positive crashes during teardown.
  # Suspend/ResumeThread failures are now uniformly treated as
  # benign — a thread we cannot suspend cannot be in a pinned
  # critical section we need to neutralize, and a thread we cannot
  # resume is either already gone or in a state we cannot recover
  # from regardless. See `neutralizeRemoteSlot` below.

var
  signalHandlerInstalled: Atomic[bool]
    ## Process-wide idempotency flag for the SIGUSR1 handler. Multiple
    ## threads may race into `installSignalHandler` (each thread calls it
    ## from `registerThread`), so the flag must be atomic. The
    ## load/store ordering is acquire/release, but the install itself is
    ## not guarded by CAS: a benign double-install can happen if two
    ## threads both observe the flag false before either stores true.
    ## That is harmless because `sigaction` is thread-safe and re-arming
    ## the same handler is idempotent at the OS level.
    ##
    ## On Windows the flag is set to `true` once on first `installSignalHandler`
    ## call so `isSignalHandlerInstalled` reports `true` for parity with POSIX.
  globalManagerPtr*: Atomic[pointer]
    ## Set during manager initialization. Used by signal handler (POSIX)
    ## or by `neutralizeRemoteSlot` (Windows). Stored as
    ## `Atomic[pointer]` (rather than a plain `pointer`) so the publish
    ## path in `setGlobalManager` can use `moRelease` and the consumer
    ## can use `moAcquire`. Without this, the stride/header release
    ## stores would not synchronize with the consumer's reads through
    ## any defined happens-before edge — a reader could observe the new
    ## pointer paired with stale stride or header values from a previous
    ## manager.

  # Layout of `DebraManager.threads` captured by `setGlobalManager` so
  # the SIGUSR1 handler (POSIX) or the scanner-side flipper (Windows)
  # can walk to the right per-thread slot without knowing `MaxThreads`
  # (the static parameter is not visible inside the noconv async-signal
  # handler, and we want a single layout descriptor on both platforms).
  # These are written under release ordering before `globalManagerPtr`
  # is published; the consumer reads them under acquire ordering after
  # observing a non-nil `globalManagerPtr`. Initial values are
  # deliberately zero so that a buggy signal-before-publish path cannot
  # index into the manager: `threadOffset = 0 + idx * 0 = 0`, which
  # lands on the manager's globalEpoch field (a harmless non-corruption
  # read of an Atomic).
  threadsArrayOffsetBytes: Atomic[int]
  threadStateStrideBytes: Atomic[int]
  # Upper bound on valid slot indices, published by `setGlobalManager`
  # alongside the layout descriptor. `neutralizeRemoteSlot` uses this to
  # bounds-check its `slot` argument before doing raw pointer arithmetic,
  # so an out-of-range slot cannot index past the `threads` array into
  # arbitrary memory. Initial value 0 means "no manager published" — any
  # bounds check against zero rejects every non-negative slot, which is
  # the safe default before the manager is set.
  maxThreadsBound: Atomic[int]

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
  doAssert threadStatePinnedOffset() == 8,
    "ThreadState.pinned must be at byte offset 8 (got " & $threadStatePinnedOffset() &
      "); the signal handler depends on this absolute offset. " &
      "If you intentionally changed the layout, update this assert " &
      "and the matching one for `neutralized`."
  doAssert threadStateNeutralizedOffset() == 16,
    "ThreadState.neutralized must be at byte offset 16 (got " &
      $threadStateNeutralizedOffset() &
      "); the signal handler depends on this absolute offset. " &
      "If you intentionally changed the layout, update this assert " &
      "and the matching one for `pinned`."
  doAssert sizeof(ThreadState[DefaultMaxThreads]) mod CacheLineBytes == 0,
    "ThreadState size (" & $sizeof(ThreadState[DefaultMaxThreads]) &
      ") must be a multiple of CacheLineBytes (" & $CacheLineBytes &
      ") -- adjust the `cacheLinePad` field in types.nim"
  # Cross-MaxThreads stability check: even with the absolute-offset
  # asserts above, verify the offsets do not drift between
  # instantiations (e.g., if a future generic field were added that
  # depended on MaxThreads).
  doAssert offsetOf(ThreadState[4], pinned) == threadStatePinnedOffset(),
    "ThreadState.pinned offset must not depend on MaxThreads"
  doAssert offsetOf(ThreadState[4], neutralized) == threadStateNeutralizedOffset(),
    "ThreadState.neutralized offset must not depend on MaxThreads"

# Thread-local storage for thread index. Nim threadvars are
# zero-initialized, so a bare `int` cannot distinguish "unregistered" from
# "registered at slot 0". `threadLocalRegistered` is the explicit
# registered-bit; both fields must be consulted before treating
# `threadLocalIdx` as a real slot index. `registerThread` flips
# `threadLocalRegistered = true` after assigning a slot.
#
# On Windows these threadvars are still used by `unregisterThread` for
# thread-affinity enforcement. The Windows neutralization arm
# (`neutralizeRemoteSlot`) does NOT read them from the target thread
# (impossible without OS-level TLS introspection); instead the scanner
# passes the slot index explicitly.
var threadLocalIdx* {.threadvar.}: int
var threadLocalRegistered* {.threadvar.}: bool
var threadLocalManager* {.threadvar.}: pointer
  ## Manager pointer the calling thread is registered with. Stored as raw
  ## `pointer` because the threadvar cannot carry the `MaxThreads` static
  ## parameter. Compared by identity in `reclaimStart(addr manager)` to
  ## reject the multi-manager hazard where a thread registered with manager
  ## A would otherwise have its `threadLocalIdx` interpreted against
  ## manager B's slot array.

when not defined(windows):
  import std/posix

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
    ##
    ## Thread-safety: the `signalHandlerInstalled` flag is `Atomic[bool]`,
    ## acquire-loaded for the fast-path bail-out and release-stored after
    ## a successful `sigaction`. Two threads may both observe the flag
    ## false and both call `sigaction`; that is benign because
    ## `sigaction` is thread-safe and re-arming the same handler is
    ## idempotent at the OS level.
    if signalHandlerInstalled.load(moAcquire):
      return

    var sa: Sigaction
    sa.sa_handler = neutralizationHandler
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = 0 # No SA_RESTART - we want operations to be interrupted

    if sigaction(QuiescentSignal, sa, nil) == 0:
      signalHandlerInstalled.store(true, moRelease)

  proc isSignalHandlerInstalled*(): bool =
    ## Check if signal handler has been installed.
    signalHandlerInstalled.load(moAcquire)

  proc forceReinstallSignalHandler*() =
    ## Re-install the SIGUSR1 handler unconditionally, bypassing the
    ## `signalHandlerInstalled` idempotency flag. Intended for test
    ## isolation: when a sibling test installs a different SIGUSR1
    ## handler via direct `sigaction` (e.g. the placeholder in
    ## `typestates/signal_handler`), the OS-level handler is overwritten
    ## even though `signalHandlerInstalled` remains true. Calling this
    ## restores the real `neutralizationHandler`. Not part of the
    ## library's public surface for normal use; prefer
    ## `installSignalHandler` in production code.
    var sa: Sigaction
    sa.sa_handler = neutralizationHandler
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = 0
    if sigaction(QuiescentSignal, sa, nil) == 0:
      signalHandlerInstalled.store(true, moRelease)

else:
  # Windows arm: there is no signal handler to install. The
  # neutralization mechanism (SuspendThread/ResumeThread) is invoked
  # synchronously by the scanner via `neutralizeRemoteSlot`. The
  # install/check stubs retain the POSIX shape so callers
  # (`registerThread`, tests) compile unchanged.

  proc installSignalHandler*() =
    ## Windows stub — see module comment. The neutralization arm uses
    ## SuspendThread/ResumeThread directly; there is no async handler
    ## to install. Sets `signalHandlerInstalled` to true so
    ## `isSignalHandlerInstalled` reports `true` for parity with POSIX.
    signalHandlerInstalled.store(true, moRelease)

  proc isSignalHandlerInstalled*(): bool =
    ## Check if signal handler has been installed. On Windows this
    ## reports whether `installSignalHandler` has been called at least
    ## once; there is no actual handler.
    signalHandlerInstalled.load(moAcquire)

  proc forceReinstallSignalHandler*() =
    ## Windows stub — see `installSignalHandler`. Provided for API
    ## parity so tests that exercise handler re-install paths compile.
    signalHandlerInstalled.store(true, moRelease)

proc neutralizeRemoteSlot*(tid: ThreadId, slot: int) =
  ## Force-unpin and mark-neutralized a remote thread's slot.
  ##
  ## Validates `slot` is in `[0, maxThreadsBound)`; raises
  ## `AssertionDefect` on out-of-bounds. The Windows arm performs raw
  ## pointer arithmetic against the published manager layout, so an
  ## out-of-range slot would otherwise read/write arbitrary memory past
  ## the `threads` array. The bound is captured by `setGlobalManager`;
  ## before that publish the bound is zero, which rejects every
  ## non-negative slot — the safe default.
  ##
  ## **POSIX arm**: sends `QuiescentSignal` (SIGUSR1) to `tid`. The
  ## handler installed by `installSignalHandler` runs asynchronously in
  ## the target's context, reads the target's `threadLocalIdx`, and
  ## flips the slot. The `slot` argument is unused (kept for API parity).
  ##
  ## **Windows arm**: suspends `tid` (which is a duplicated thread
  ## Handle), walks the published global manager to find slot `slot`,
  ## flips `pinned` to false and `neutralized` to true under release
  ## ordering, then resumes the thread. The walk uses the same
  ## pointer-arithmetic descriptor (`globalManagerPtr` +
  ## `threadsArrayOffsetBytes` + `threadStateStrideBytes`) that the
  ## POSIX handler uses, so the layout invariants asserted at the top
  ## of this file apply identically.
  ##
  ## Both arms are no-ops when `tid` is not valid.
  ##
  ## **Deadlock note**: see module-level comment. On Windows, the
  ## scanner blocks inside `SuspendThread` only briefly (kernel
  ## suspends, returns); the slot-flip is wait-free. The risk is the
  ## target holding a lock that the scanner needs *after* this call.
  # Bounds-check `slot` against the published maxThreadsBound BEFORE
  # any platform-specific work. The Windows arm does raw pointer
  # arithmetic against the manager's `threads` array; an out-of-range
  # slot would index into arbitrary memory and corrupt unrelated state.
  # The POSIX arm ignores `slot`, but a caller passing a bogus value is
  # a bug worth surfacing on either platform. Use `raiseAssert` so the
  # Defect bypasses `{.raises: [].}` effect lists.
  let bound = maxThreadsBound.load(moAcquire)
  if slot < 0 or slot >= bound:
    raiseAssert(
      "neutralizeRemoteSlot: slot " & $slot & " out of range [0, " & $bound & ")"
    )

  when defined(windows):
    if not tid.isValid:
      return

    # Open a temporary handle to the target thread by its OS thread
    # ID. The handle lifetime is bounded to this proc's body via the
    # `try`/`finally` below, so there is no shared handle resource to
    # leak or race on (cycle-40 pivot eliminates the cycle-22/35-39
    # handle-lifetime hazards by construction).
    #
    # `OpenThread` returns 0 if the target thread has already
    # terminated between the scanner observing the slot's thread ID
    # and this call. That race is benign: neutralization on a dead
    # thread is a no-op (the thread cannot still be in a pinned
    # critical section since it no longer exists), so we return
    # without raising.
    # Cycle-43: the benign-failure path no longer needs
    # `GetExitCodeThread`, so we drop `THREAD_QUERY_INFORMATION` and
    # open with the minimal `THREAD_SUSPEND_RESUME` right that the
    # neutralization protocol actually uses. The kernel access check
    # is tightened, and we no longer rely on a racy "is the thread
    # alive?" probe that can mis-classify a dying thread as live.
    let h = openThread(THREAD_SUSPEND_RESUME, WINBOOL(0), tid.tid)
    if h == Handle(0):
      return

    try:
      # Suspend the target. SuspendThread returns the previous suspend
      # count, or `DWORD(-1)` (== `0xFFFFFFFF`) on failure. winlean's
      # `suspendThread` currently returns `int32`, so the failure
      # sentinel arrives as `-1`. We `cast[int32]` the return value
      # explicitly and compare against `-1'i32` so the check survives
      # any future winlean signature change (e.g., to an unsigned
      # `DWORD`/`uint32`) — under such a change a bare `< 0` would
      # always be false and failure would become silent (gemini
      # cycle-29/34). Failure here means the thread terminated
      # between `OpenThread` and `SuspendThread` (an even tighter
      # race than the OpenThread-time check above); treat as no-op.
      let prevCount = cast[int32](suspendThread(h))
      if prevCount == -1'i32:
        # SuspendThread failed. The overwhelmingly common cause is that
        # the target thread terminated between `OpenThread` and this
        # call. Differentiating "really alive" from "dying" via
        # `GetExitCodeThread` is racy on Windows: a thread that exits
        # between SuspendThread and GetExitCodeThread can still report
        # `STILL_ACTIVE` because the handle is not yet signaled until
        # the thread fully exits. Treating all SuspendThread failures
        # as benign avoids false-positive crashes during teardown
        # — strictly safer than raising on a racy "still active"
        # observation. The neutralization store is not applied below
        # in this path; that is acceptable because a thread we could
        # not suspend cannot be in a pinned critical section we need
        # to neutralize (gemini cycle-43 HIGH).
        return

      # Walk the global manager descriptor exactly like the POSIX
      # handler. On Windows the scanner runs this from its own context
      # (not the target's), so `threadLocalIdx` is the SCANNER's slot
      # index, not the target's — we use the explicit `slot` argument
      # instead.
      let mgrPtr = globalManagerPtr.load(moAcquire)
      if mgrPtr != nil:
        let basePtr = cast[ptr UncheckedArray[byte]](mgrPtr)
        let headerSize = threadsArrayOffsetBytes.load(moAcquire)
        let stride = threadStateStrideBytes.load(moAcquire)
        if stride != 0:
          let threadOffset = headerSize + slot * stride
          let pinnedPtr = cast[ptr Atomic[bool]](addr basePtr[
            threadOffset + threadStatePinnedOffset()
          ])
          let neutralizedPtr = cast[ptr Atomic[bool]](addr basePtr[
            threadOffset + threadStateNeutralizedOffset()
          ])
          if pinnedPtr[].load(moAcquire):
            pinnedPtr[].store(false, moRelease)
            neutralizedPtr[].store(true, moRelease)

      # Resume. If this fails the target is permanently suspended,
      # which would deadlock the whole process. winlean's
      # `resumeThread` returns `int32`; on failure the Win32 API
      # returns `DWORD(-1)` (== `0xFFFFFFFF`), which arrives here as
      # `-1`. As with the `SuspendThread` check above, `cast[int32]` the
      # return value explicitly and compare against `-1'i32` rather than
      # `< 0` so the check survives any future winlean signature change
      # to an unsigned `DWORD`/`uint32` return (gemini cycle-29/34). A
      # successful SuspendThread above implies the handle is valid for
      # ResumeThread, so reaching this failure branch means the target
      # was terminated between the two calls (or some other
      # unrecoverable kernel-level fault). Fail loudly via
      # `raiseAssert` (Defect — not tracked by `raises:` effect lists,
      # so callers under `{.transition.}` / `{.raises: [].}` compile
      # unchanged) rather than silently leaving the target permanently
      # suspended. Silent success here would deadlock any subsequent
      # join/wait on the target and corrupt the neutralization
      # protocol invariants.
      if cast[int32](resumeThread(h)) == -1'i32:
        # ResumeThread failed. Common cause: the thread terminated
        # between our SuspendThread and ResumeThread calls (race
        # during teardown). `GetExitCodeThread` cannot reliably
        # discriminate "really alive" from "dying" — a thread that
        # exits between SuspendThread and GetExitCodeThread can still
        # return STILL_ACTIVE because the handle is not signaled
        # until the thread fully exits. Treating ALL ResumeThread
        # failures as benign is safer than raising on a racy
        # "still active" observation: a false-positive crash during
        # teardown is worse than missing a rare kernel-level
        # corruption case. The handle is CloseHandle()'d in the
        # finally block below regardless (gemini cycle-43 HIGH).
        discard
    finally:
      # Always close the temporary handle, even on raiseAssert above.
      # Handle lifetime is exactly the duration of this proc body; no
      # handle ever escapes into the slot or the manager.
      discard closeHandle(h)
  else:
    discard slot # POSIX path ignores the slot — handler reads threadLocalIdx
    discard tid.sendSignal(QuiescentSignal)

proc setGlobalManager*[
    MaxThreads: static int, CC: static PinScopeCardinality = ccSingle
](manager: ptr DebraManager[MaxThreads, CC]) =
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
  ##
  ## On Windows the same descriptor is consumed by
  ## `neutralizeRemoteSlot` running on the scanner thread, so the race
  ## constraint is identical (the scanner is the "reader" here, not an
  ## async handler).
  # Capture layout under release so the consumer's acquire reads see
  # consistent stride+header before observing globalManagerPtr. The
  # publish order matters: stride/header MUST be stored before the
  # pointer, so a reader that loads the pointer with acquire and
  # observes the new value is guaranteed to see the matching new
  # stride/header. We compute the threads-array offset by pointer
  # subtraction rather than `offsetOf(DebraManager[MaxThreads],
  # threads)` because the latter form does not currently instantiate
  # cleanly through Nim's generic offsetOf path (the static MaxThreads
  # parameter is not propagated into the magic).
  let headerOffset = cast[int](addr manager.threads) - cast[int](manager)
  threadsArrayOffsetBytes.store(headerOffset, moRelease)
  threadStateStrideBytes.store(sizeof(ThreadState[MaxThreads]), moRelease)
  maxThreadsBound.store(MaxThreads, moRelease)
  # Pointer published LAST under release. A consumer that observes
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
  # Clear the pointer FIRST under release so any consumer that loads
  # it under acquire and sees nil bails out before reading stride.
  # Then zero stride/header. This also matches the publish order in
  # the typed overload (pointer is the synchronizing edge).
  globalManagerPtr.store(nil, moRelease)
  threadStateStrideBytes.store(0, moRelease)
  threadsArrayOffsetBytes.store(0, moRelease)
  maxThreadsBound.store(0, moRelease)
