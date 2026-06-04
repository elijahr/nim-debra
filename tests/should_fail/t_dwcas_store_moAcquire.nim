## Should-fail fixture: DWCAS store must reject moAcquire/moAcquireRelease/moConsume.
##
## Mirrors validStoreOrder for the 1-8-byte surface; the 16-byte store
## should enforce the same constraint at compile time.
##
## Pinned substring: "moAcquire / moAcquireRelease / moConsume is not a valid"

import debra/atomics

var a: Atomic[Pair[uint64, uint64]]
a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64), moAcquire)
