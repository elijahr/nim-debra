## Constants for DEBRA+ implementation.

import std/posix

const
  DefaultMaxThreads* = 64
    ## Default maximum number of threads that can be registered.

  CacheLineBytes* = 64
    ## Cache line size for alignment to prevent false sharing.

let
  QuiescentSignal* = SIGUSR1
    ## POSIX signal used for thread neutralization.
