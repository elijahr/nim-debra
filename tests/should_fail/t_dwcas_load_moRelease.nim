## Should-fail fixture: DWCAS load must reject moRelease/moAcquireRelease.
##
## Mirrors validLoadOrder for the 1-8-byte surface; the 16-byte load
## should enforce the same constraint at compile time.
##
## Pinned substring: "moRelease / moAcquireRelease is not a valid memory order for load"

import debra/atomics

var a: Atomic[Pair[uint64, uint64]]
discard a.load(moRelease)
