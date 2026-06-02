## DWCAS per-callsite silencer verification fixture (impl plan Task 19).
##
## Compile-only test: passes a sub-seq_cst memory order to a 16-byte CAS
## INSIDE a `dwcasOrderRelaxedCAS:` block. The wrapper MUST suppress the
## `{.warning.}` that would otherwise fire (see Task 18 fixture). Verified
## by the stderr-grep harness in `run_dwcas_warning_check.sh` (and the CI
## step in Task 23).
import debra/atomics

var a: Atomic[Pair[uint64, uint64]]
a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
var expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
dwcasOrderRelaxedCAS:
  discard a.compareExchangeStrong(
    expected, Pair[uint64, uint64](first: 3'u64, second: 4'u64), moRelease, moRelaxed
  )
