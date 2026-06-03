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

  type ThreadId* = object
    ## Platform-abstracted thread identifier (Windows arm).
    ##
    ## Carries a duplicated `Handle` with DUPLICATE_SAME_ACCESS from the
    ## pseudo-handle returned by `GetCurrentThread`. The duplicated
    ## handle is valid across threads and remains valid until
    ## `CloseHandle` is called on it. The library does not currently
    ## close per-thread handles eagerly because the slot is reused by
    ## the same OS thread within a process lifetime; on heavy
    ## register/unregister churn a future revision could add an
    ## explicit close on `unregisterThread` (see `KNOWN_GAPS` in the
    ## Windows SMR notes).
    handle*: Handle

  let InvalidThreadId* = ThreadId(handle: Handle(0))
    ## Sentinel value representing no thread. `Handle(0)` is INVALID for
    ## thread handles on Windows (real handles are always non-zero), so
    ## the zero handle is a safe sentinel.

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
    ## Note: handles to the SAME OS thread but obtained via separate
    ## DuplicateHandle calls compare UNEQUAL. The scanner uses
    ## `ThreadId` equality only against handles that were stored into
    ## the manager via `mgr.threads[i].threadId.store(currentThreadId(),
    ## ...)` by the owning thread, so the same-handle property holds
    ## within the protocol's call shapes. If a caller needs identity
    ## comparison across separately-duplicated handles, they must use
    ## `GetThreadId` (not exposed here).
    a.handle == b.handle

  proc `$`*(tid: ThreadId): string =
    ## Render a `ThreadId` for diagnostics. Renders the handle as a
    ## hex integer; used by `unittest2.check` when an equality
    ## assertion involving a `ThreadId` fails.
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
