# src/debra/thread_id.nim

## Platform-abstracted thread identifier for signal delivery.
##
## On POSIX systems, pthread_kill requires different types on different platforms:
## - Linux: pthread_t (Pthread)
## - macOS: pthread_t (which can accept Pid)
##
## This module provides a unified ThreadId type that works correctly on all platforms.

import std/posix
import std/strutils

type ThreadId* = object
  ## Platform-abstracted thread identifier for use with pthread_kill.
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
  ## Send a signal to the thread identified by tid.
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
