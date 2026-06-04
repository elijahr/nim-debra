## DWCAS objdump verification fixture (design §5.3 / §7.2).
##
## Tiny -d:release Nim TU that exercises every DWCAS op family so the
## emitted binary contains all relevant native instructions. CI runs
## `objdump -d` on the result and verifies (per design §5.3 regex
## table):
##
##   x86_64 (ubuntu-24.04)      : `cmpxchg16b` (or `lock cmpxchg16b`)
##   aarch64 (ubuntu-24.04-arm,  : `caspal?` (LSE) or `ldaxp/stlxp` (LL/SC)
##            macos-15)
##
## A counter-test recompiles this fixture with `--passC:-mno-cx16` on
## ubuntu-24.04 and asserts that the compile FAILS (gate 3 fires).
## Both checks together prove the regex discriminates between native
## emit and libcall fallback.

import debra/atomics

var a: Atomic[Pair[uint64, uint64]]
a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
let r = a.load()
let prev = a.exchange(Pair[uint64, uint64](first: 3'u64, second: 4'u64))
var expected = r
discard
  a.compareExchangeStrong(expected, Pair[uint64, uint64](first: 5'u64, second: 6'u64))
discard
  a.compareExchangeWeak(expected, Pair[uint64, uint64](first: 7'u64, second: 8'u64))

# Force the ops to not be dead-code eliminated by the optimizer.
echo prev.first, " ", prev.second
