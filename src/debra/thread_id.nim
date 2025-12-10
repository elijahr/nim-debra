# src/debra/thread_id.nim

## Platform-abstracted thread identifier for signal delivery.
##
## On POSIX systems, pthread_kill requires different types on different platforms:
## - Linux: pthread_t (Pthread)
## - macOS: pthread_t (which can accept Pid)
##
## This module provides a unified ThreadId type that works correctly on all platforms.

import std/posix

type
  ThreadId* = object
    ## Platform-abstracted thread identifier for use with pthread_kill.
    handle: Pthread

const
  InvalidThreadId* = ThreadId(handle: Pthread(0))
    ## Sentinel value representing no thread.

proc currentThreadId*(): ThreadId =
  ## Get the ThreadId of the current thread.
  ThreadId(handle: pthread_self())

proc `==`*(a, b: ThreadId): bool =
  ## Compare two ThreadIds for equality.
  a.handle == b.handle

proc isValid*(tid: ThreadId): bool =
  ## Check if this ThreadId represents a valid thread.
  tid.handle != Pthread(0)

proc sendSignal*(tid: ThreadId, sig: cint): cint =
  ## Send a signal to the thread identified by tid.
  ## Returns 0 on success, error code on failure.
  pthread_kill(tid.handle, sig)

proc unsafeThreadId*(handle: Pthread): ThreadId =
  ## Create a ThreadId from a raw Pthread handle.
  ## For testing purposes only.
  ThreadId(handle: handle)

proc unsafeThreadIdFromInt*(value: int): ThreadId =
  ## Create a ThreadId from an integer value.
  ## For testing purposes only - creates a fake thread ID.
  ThreadId(handle: cast[Pthread](value))
