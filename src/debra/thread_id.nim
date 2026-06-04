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
## - **Windows**: the identifier is the raw OS thread ID (`uint32`,
##   the `DWORD` returned by `GetCurrentThreadId`). It is OS-managed —
##   no kernel handle is allocated, duplicated, or stored. Remote
##   neutralization uses `SuspendThread` / `ResumeThread`: the scanner
##   opens a temporary handle via `OpenThread(THREAD_SUSPEND_RESUME)`,
##   suspends the target, directly flips its slot via the same
##   pointer-arithmetic walk that the POSIX signal handler uses,
##   resumes, then `CloseHandle`s in a `finally` block. Handle
##   lifetime is the duration of a single `neutralizeRemoteSlot` call.
##   This avoids the async-signal-safety constraints of the POSIX path;
##   `signal.nim`'s handler-install machinery is a no-op on Windows.
##   The earlier design (v0.10.0-dev, cycles 19-39) stored a duplicated
##   handle in the slot; that design carried a bounded handle leak on
##   slot churn and a use-after-close race between scanner and
##   unregister. The on-demand `OpenThread`/`CloseHandle` design
##   eliminates both by construction (gemini cycle-40).
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

  proc getCurrentThreadIdRaw(): uint32 {.
    stdcall, dynlib: "kernel32", importc: "GetCurrentThreadId", sideEffect
  .}
    ## Win32 `GetCurrentThreadId` — returns the OS-level DWORD identifier
    ## of the calling thread without allocating a handle. This is the
    ## sole ingest path for the Windows `ThreadId`: the raw OS thread
    ## ID is stored directly, no kernel object is involved.

  # OpenThread acquires a fresh handle to an existing thread by its
  # OS-level thread ID. Used by `neutralizeRemoteSlot` to scope a
  # SuspendThread/ResumeThread pair around the slot flip; the handle
  # is CloseHandle'd in a `finally` block so its lifetime is bounded
  # to that critical section. Returns 0 on failure (e.g. target
  # terminated between the scanner observing its thread ID and the
  # OpenThread call); callers must treat 0 as "thread is gone,
  # neutralization is moot".
  const THREAD_SUSPEND_RESUME* = 0x0002'u32
  proc openThread*(
    dwDesiredAccess: uint32, bInheritHandle: WINBOOL, dwThreadId: uint32
  ): Handle {.stdcall, dynlib: "kernel32", importc: "OpenThread", sideEffect.}

  type ThreadId* = object
    ## Platform-abstracted thread identifier (Windows arm).
    ##
    ## Carries the raw OS thread ID (`uint32`, the `DWORD` returned by
    ## `GetCurrentThreadId`). OS-managed — no kernel handle is
    ## duplicated, stored, or owned. Identity is structural: two
    ## `ThreadId` values for the same OS thread compare equal by
    ## direct integer comparison.
    ##
    ## Cross-thread neutralization (`SuspendThread`/`ResumeThread`)
    ## requires a kernel handle, but the handle is acquired on demand
    ## inside `neutralizeRemoteSlot` via `OpenThread`, used under a
    ## `try`/`finally` for the suspend-flip-resume critical section,
    ## and `CloseHandle`d before return. Handle lifetime is bounded to
    ## that critical section; no handle is ever stored in the slot or
    ## the manager.
    ##
    ## This eliminates the bounded handle leak (slot churn) and the
    ## use-after-close race against the scanner that the earlier
    ## duplicated-handle design carried (cycles 19-39 traversed
    ## various mitigations before the cycle-40 pivot).
    ##
    ## Keeping `ThreadId` at 8 bytes (same as POSIX) avoids triggering
    ## the 16-byte DWCAS path in `Atomic[ThreadId]`. A bare `uint32`
    ## (4 bytes) would still be lock-free, but the object wrapper is
    ## retained for API parity with the POSIX arm and to keep the
    ## `unsafeThreadIdFromInt` test helpers compiling unchanged.
    tid*: uint32

  let InvalidThreadId* = ThreadId(tid: 0'u32)
    ## Sentinel value representing no thread. The Win32 thread-ID
    ## space starts at 4 (the kernel allocates DWORDs in multiples of
    ## 4, skipping 0); zero is guaranteed never to alias a real
    ## thread.

  proc currentThreadId*(): ThreadId {.raises: [].} =
    ## Get the ThreadId of the current thread.
    ##
    ## Zero allocation: returns the raw `GetCurrentThreadId()` result.
    ## The Windows arm formerly allocated a fresh kernel handle via
    ## `DuplicateHandle(GetCurrentThread())` per call; the cycle-40
    ## pivot eliminated that. There is no longer any handle resource
    ## to track, leak, or race against.
    ThreadId(tid: getCurrentThreadIdRaw())

  proc isCurrent*(tid: ThreadId): bool {.inline, raises: [].} =
    ## Non-allocating identity check: returns true iff `tid` refers to
    ## the calling thread. Direct `uint32` compare against
    ## `GetCurrentThreadId()`.
    if tid.tid == 0'u32:
      return false
    tid.tid == getCurrentThreadIdRaw()

  proc `==`*(a, b: ThreadId): bool {.inline.} =
    ## Compare two ThreadIds for equality. Direct `uint32` compare —
    ## the OS thread ID is the canonical identity, so structural
    ## equality is the same as thread-identity equality.
    a.tid == b.tid

  proc `$`*(tid: ThreadId): string =
    ## Render a `ThreadId` for diagnostics. Renders the OS thread ID
    ## as a hex integer; used by `unittest2.check` when an equality
    ## assertion involving a `ThreadId` fails.
    "ThreadId(0x" & tid.tid.toHex & ")"

  proc isValid*(tid: ThreadId): bool {.inline.} =
    ## Check if this ThreadId represents a valid thread.
    tid.tid != 0'u32

  proc unsafeThreadId*(tid: uint32): ThreadId =
    ## Create a ThreadId from a raw OS thread ID (`uint32`).
    ## For testing purposes only.
    ThreadId(tid: tid)

  proc unsafeThreadIdFromInt*(value: int): ThreadId =
    ## Create a ThreadId from an integer value.
    ## For testing purposes only - creates a fake thread ID.
    ##
    ## Unlike the previous DuplicateHandle-based design, fake non-zero
    ## thread IDs no longer trigger any kernel call: the `==` operator
    ## is a direct `uint32` compare. Fabricated IDs compare correctly
    ## against each other and against `InvalidThreadId`. The Windows
    ## test skip for "different fake IDs" in `t_thread_id` is no
    ## longer needed (but retained for now to avoid unrelated test
    ## churn in this pivot commit).
    ThreadId(tid: cast[uint32](value and 0xFFFF_FFFF))

  # `sendSignal` is intentionally NOT defined on Windows. Cross-thread
  # neutralization on Windows uses `neutralizeRemoteSlot` (defined in
  # signal.nim) which opens a temporary handle, suspends, flips,
  # resumes, closes. The POSIX-only signal-delivery surface
  # (`sendSignal`, `QuiescentSignal`) is not portable and exposing a
  # Windows stub would invite call sites to assume signal-delivery
  # semantics that this platform cannot provide.
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

  proc isCurrent*(tid: ThreadId): bool {.inline.} =
    ## Non-allocating identity check: returns true iff `tid` refers to
    ## the calling thread. Mirrors the Windows arm — on POSIX
    ## `pthread_self()` is cheap (no kernel call), so the no-alloc
    ## guarantee is structural rather than a meaningful perf win, but
    ## the API parity matters for the cross-platform call site in
    ## `neutralize.scanAndSignal`.
    pthread_equal(tid.handle, pthread_self()) != 0

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
