## Should-fail fixture: DWCAS compareExchangeStrong must reject
## failure-order moRelease (validCasFailureOrder, already called by the
## 16-byte CAS surface). Pinned to confirm the gate is still wired.
##
## Pinned substring: "compareExchange failure order"

import debra/atomics

var a: Atomic[Pair[uint64, uint64]]
var expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
discard a.compareExchangeStrong(
  expected,
  Pair[uint64, uint64](first: 3'u64, second: 4'u64),
  moSequentiallyConsistent,
  moRelease,
)
