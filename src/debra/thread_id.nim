# src/debra/thread_id.nim

## Platform-abstracted thread identifier for thread neutralization.
##
## DEBRA+ needs a way to (a) identify the calling thread and (b) interrupt
## a stalled remote thread so the reclaimer can advance. The mechanism is
## platform-specific:
##
## - **POSIX** (Linux, macOS, BSD): the identifier is a `Pthread`. Remote
##   neutralization is done by `pthread_kill(tid, SIGUSR1)` which delivers
##   an asynchronous signal; the SIGUSR1 handler in `signal.nim` flips
##   the target slot's `pinned`/`neutralized` flags. The `sendSignal`
##   proc is the primary entry point on POSIX.
##
## - **Windows**: the identifier is a duplicated thread `Handle` with
##   `THREAD_ALL_ACCESS` (via `DuplicateHandle` of the pseudo-handle
##   returned by `GetCurrentThread`). Remote neutralization uses
##   `SuspendThread` / `ResumeThread`: the scanner suspends the target,
##   directly flips its slot via the same pointer-arithmetic walk that
##   the POSIX signal handler uses, then resumes. This avoids the
##   async-signal-safety constraints of the POSIX path; `signal.nim`'s
##   handler-install machinery is a no-op on Windows.
##
## **Deadlock constraint (both platforms)**: do NOT call DEBRA reclamation
## while holding a lock that other DEBRA-using threads might be blocked
## on. On POSIX the SIGUSR1 handler runs in the target's context and may
## need to acquire shared state; on Windows a `SuspendThread`'d target
## that holds a lock will deadlock the scanner if the scanner waits on
## that lock. Same hazard, different mechanism.
##
## Cross-thread state mutation (the slot flip) lives in
## `neutralizeRemoteSlot` so the call site in `neutralize.scanAndSignal`
## stays platform-neutral.

import std/strutils

when defined(windows):
  import std/winlean

  # GetCurrentThread returns a pseudo-handle (-2) that is only valid in
  # the calling thread's context. winlean does not export it; importc
  # directly. The pseudo-handle must be passed to DuplicateHandle to
  # obtain a real, cross-thread-usable handle.
  proc getCurrentThread(): Handle {.
    stdcall, dynlib: "kernel32", importc: "GetCurrentThread", sideEffect
  .}

  # GetThreadId returns the OS-level thread ID (DWORD) for a given
  # thread handle. Used for identity comparison: two `Handle` values
  # for the same OS thread (e.g. obtained via separate
  # `DuplicateHandle` calls) compare UNEQUAL, but their `GetThreadId`
  # results are equal. Self-signal detection in `scanAndSignal`
  # depends on this — without it the scanner would `SuspendThread` on
  # its own handle and deadlock.
  proc getThreadIdFromHandle(
    h: Handle
  ): uint32 {.stdcall, dynlib: "kernel32", importc: "GetThreadId", sideEffect.}

  type ThreadId* = object
    ## Platform-abstracted thread identifier (Windows arm).
    ##
    ## Carries a duplicated thread `Handle` (8 bytes) from
    ## `DuplicateHandle(GetCurrentThread(), DUPLICATE_SAME_ACCESS)`.
    ## The handle is valid across threads (unlike the calling-thread
    ## pseudo-handle returned by `GetCurrentThread`) and is the target
    ## argument to `SuspendThread` / `ResumeThread`.
    ##
    ## **Identity vs. handle**: each call to `currentThreadId()`
    ## allocates a FRESH handle, so handle values are NOT comparable
    ## across calls. The `==` operator below uses `GetThreadId(handle)`
    ## to extract the stable OS-level thread ID for comparison — that
    ## value is the same across all duplicated handles of the same
    ## thread. Self-signal detection in `scanAndSignal` depends on
    ## this; without it the scanner would `SuspendThread` on its own
    ## handle and deadlock.
    ##
    ## Keeping `ThreadId` at 8 bytes (same as POSIX) avoids triggering
    ## the 16-byte DWCAS path in `Atomic[ThreadId]`. The DWCAS path is
    ## only specialized for `Atomic[Pair[A, B]]`; a 16-byte
    ## `Atomic[ThreadId]` would fail the `nonAtomicType` dispatch and
    ## the runtime alignment check would need 16-byte alignment on the
    ## containing field — both avoided by stashing identity in
    ## `GetThreadId(handle)` instead of an inline field.
    ##
    ## The duplicated handle remains valid until `CloseHandle` is called
    ## on it. KNOWN_GAP (v0.10.0): the library does not currently close
    ## per-thread handles eagerly. An earlier fix (898c160) closed them
    ## on `unregisterThread` and on scanner exit, but the unregister-side
    ## close introduced a use-after-close race against concurrent
    ## `scanAndSignal` callers (the scanner had already loaded the handle
    ## into a local before the unregister ran). Both sites were reverted
    ## in cycle-22. The leak is bounded for typical workloads (~one
    ## handle per `currentThreadId()` call, capped by the Windows 16K
    ## per-process quota for the test surface). A future revision
    ## (v0.11.0) will reintroduce closing via a deferred-close mechanism
    ## that drains handles only after no scanner can hold a reference —
    ## e.g. a per-manager close queue flushed at end-of-scan-epoch.
    handle*: Handle

  let InvalidThreadId* = ThreadId(handle: Handle(0))
    ## Sentinel value representing no thread. `Handle(0)` is INVALID
    ## for thread handles on Windows; the `==` operator special-cases
    ## the zero handle to avoid calling `GetThreadId(0)` (which would
    ## return 0 but emit a Win32 error).

  proc currentThreadId*(): ThreadId {.raises: [].} =
    ## Get the ThreadId of the current thread.
    ##
    ## Returns a `Handle` duplicated from `GetCurrentThread()`'s
    ## pseudo-handle, with full access rights so the scanner can later
    ## call `SuspendThread`/`ResumeThread`. `DuplicateHandle` on the
    ## current-thread pseudo-handle within the same process is documented
    ## by MSDN to fail only on invalid arguments (which the call shape
    ## here cannot produce), so the API surface is `{.raises: [].}` for
    ## parity with the POSIX arm. On the impossible failure case a
    ## `doAssert` fires with the Windows error code — better than
    ## silently producing an invalid handle that would later misroute
    ## SuspendThread to nowhere.
    var dup: Handle = Handle(0)
    let ok = duplicateHandle(
      getCurrentProcess(),
      getCurrentThread(),
      getCurrentProcess(),
      addr dup,
      0, # dwDesiredAccess ignored when DUPLICATE_SAME_ACCESS is set
      0, # bInheritHandle = FALSE
      DUPLICATE_SAME_ACCESS,
    )
    doAssert ok != 0,
      "DuplicateHandle(GetCurrentThread()) failed; this is not expected " &
        "for the in-process pseudo-handle call shape"
    ThreadId(handle: dup)

  proc `==`*(a, b: ThreadId): bool =
    ## Compare two ThreadIds for equality.
    ##
    ## Identity uses `GetThreadId(handle)` to extract the stable OS
    ## thread ID from each handle. Direct handle comparison would
    ## misreport same-thread calls as UNEQUAL because each
    ## `currentThreadId()` allocates a fresh handle via
    ## `DuplicateHandle` — and `scanAndSignal`'s self-signal guard
    ## depends on the same-thread check being correct (otherwise the
    ## scanner deadlocks by `SuspendThread`ing its own handle).
    ##
    ## The `Handle(0)` sentinel is special-cased: two zero handles
    ## compare equal without calling `GetThreadId(0)` (which would
    ## set Win32 last-error). One zero and one non-zero compare
    ## unequal trivially.
    if a.handle == Handle(0) and b.handle == Handle(0):
      true
    elif a.handle == Handle(0) or b.handle == Handle(0):
      false
    else:
      getThreadIdFromHandle(a.handle) == getThreadIdFromHandle(b.handle)

  proc `$`*(tid: ThreadId): string =
    ## Render a `ThreadId` for diagnostics. Renders the underlying
    ## handle as a hex integer; used by `unittest2.check` when an
    ## equality assertion involving a `ThreadId` fails.
    "ThreadId(0x" & cast[uint](tid.handle).toHex & ")"

  proc isValid*(tid: ThreadId): bool =
    ## Check if this ThreadId represents a valid thread.
    tid.handle != Handle(0)

  proc unsafeThreadId*(handle: Handle): ThreadId =
    ## Create a ThreadId from a raw Handle.
    ## For testing purposes only.
    ThreadId(handle: handle)

  proc unsafeThreadIdFromInt*(value: int): ThreadId =
    ## Create a ThreadId from an integer value.
    ## For testing purposes only - creates a fake thread ID.
    ##
    ## The handle stored here is not a real thread handle, so the
    ## `==` operator's `GetThreadId` call would fail at runtime if a
    ## fake non-zero value were compared. Tests that compare
    ## fabricated IDs to each other rely on the `Handle(0)`
    ## special-case in `==`, so the integer-distinct unit tests work
    ## only for the zero / non-zero discrimination — not for general
    ## fake-vs-fake equality. The POSIX test for "different fake IDs"
    ## passes there because POSIX `==` is structural; the Windows
    ## equivalent test path is therefore skipped in `t_thread_id`.
    ThreadId(handle: cast[Handle](value))

  # `sendSignal` is intentionally NOT defined on Windows. Cross-thread
  # neutralization on Windows uses `neutralizeRemoteSlot` (defined below
  # via include after the POSIX arm) which suspends, flips, resumes.
  # The POSIX-only signal-delivery surface (`sendSignal`,
  # `QuiescentSignal`) is not portable and exposing a Windows stub
  # would invite call sites to assume signal-delivery semantics that
  # this platform cannot provide.
else:
  import std/posix

  type ThreadId* = object ## Platform-abstracted thread identifier (POSIX arm).
    handle: Pthread

  let InvalidThreadId* = ThreadId(handle: cast[Pthread](0))
    ## Sentinel value representing no thread.
    ## `cast` (rather than `Pthread(0)`) is required because on some POSIX
    ## platforms (e.g. macOS) `Pthread` is an opaque struct pointer, and the
    ## C++ backend rejects integer-to-pointer conversions outside of a cast.

  proc currentThreadId*(): ThreadId =
    ## Get the ThreadId of the current thread.
    ThreadId(handle: pthread_self())

  proc `==`*(a, b: ThreadId): bool =
    ## Compare two ThreadIds for equality.
    a.handle == b.handle

  proc `$`*(tid: ThreadId): string =
    ## Render a `ThreadId` for diagnostics. The auto-generated stringifier
    ## tries to format the underlying `Pthread` (an opaque struct pointer on
    ## some POSIX platforms) as an integer, which fails to compile; we
    ## render the pointer bits as hex instead. Used by `unittest2.check`
    ## when an equality assertion involving a `ThreadId` fails.
    "ThreadId(0x" & cast[uint](tid.handle).toHex & ")"

  proc isValid*(tid: ThreadId): bool =
    ## Check if this ThreadId represents a valid thread.
    tid.handle != cast[Pthread](0)

  proc sendSignal*(tid: ThreadId, sig: cint): cint =
    ## Send a signal to the thread identified by tid. **POSIX only.**
    ##
    ## Returns 0 on success. Returns `ESRCH` immediately when `tid` equals
    ## `InvalidThreadId`; otherwise returns the error code from `pthread_kill`.
    ##
    ## Note: POSIX explicitly leaves `pthread_kill` with an invalid `pthread_t`
    ## as undefined behavior. Apple's libpthread happens to validate and return
    ## `ESRCH`, but glibc dereferences the handle and may segfault. Callers
    ## must only pass either a live thread's id or `InvalidThreadId`; passing a
    ## fabricated non-zero handle is unsupported.
    if not tid.isValid:
      return ESRCH
    pthread_kill(tid.handle, sig)

  proc unsafeThreadId*(handle: Pthread): ThreadId =
    ## Create a ThreadId from a raw Pthread handle.
    ## For testing purposes only.
    ThreadId(handle: handle)

  proc unsafeThreadIdFromInt*(value: int): ThreadId =
    ## Create a ThreadId from an integer value.
    ## For testing purposes only - creates a fake thread ID.
    ThreadId(handle: cast[Pthread](value))
