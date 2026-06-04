## Constants for DEBRA+ implementation.

const
  DefaultMaxThreads* = 64 ## Default maximum number of threads that can be registered.

  CacheLineBytes* {.intdefine.}: int = 64
    ## Cache line size for alignment to prevent false sharing. Defaults to
    ## 64 (x86_64, AArch64). Override with `-d:CacheLineBytes=128` on
    ## Apple Silicon, PowerPC, or any target where the L1 cache line is
    ## wider, otherwise the per-slot padding in `ThreadState` will not
    ## actually separate adjacent slots into distinct cache lines.

when defined(windows):
  # Windows has no analog of SIGUSR1; the neutralization protocol uses
  # SuspendThread/ResumeThread directly (see `thread_id.nim` and
  # `signal.nim` for the Windows arm of the protocol). `QuiescentSignal`
  # is retained as a compile-time-only stub so call sites that pass it
  # to platform-neutral helpers compile, but it has no signal-delivery
  # meaning on Windows.
  const QuiescentSignal*: cint = 0
    ## Windows stub — see module comment. Not a real signal number.
else:
  import std/posix
  let QuiescentSignal* = SIGUSR1 ## POSIX signal used for thread neutralization.
