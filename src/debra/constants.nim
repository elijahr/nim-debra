## Constants for DEBRA+ implementation.

import std/posix

const
  DefaultMaxThreads* = 64 ## Default maximum number of threads that can be registered.

  CacheLineBytes* {.intdefine.}: int = 64
    ## Cache line size for alignment to prevent false sharing. Defaults to
    ## 64 (x86_64, AArch64). Override with `-d:CacheLineBytes=128` on
    ## Apple Silicon, PowerPC, or any target where the L1 cache line is
    ## wider, otherwise the per-slot padding in `ThreadState` will not
    ## actually separate adjacent slots into distinct cache lines.

let QuiescentSignal* = SIGUSR1 ## POSIX signal used for thread neutralization.
