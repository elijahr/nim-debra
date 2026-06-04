## DWCAS memory-order warning emission fixture (impl plan Task 18).
##
## Compile-only test: passes a sub-seq_cst memory order to a 16-byte op,
## which MUST emit a `{.warning.}` per design §3. Verification is the
## stderr-grep harness in `tests/compile_only/run_dwcas_warning_check.nims`
## (and the CI step in Task 23). The fixture itself MUST compile cleanly
## (warnings are not errors); the harness greps stderr for the warning
## substring.
import debra/atomics

var a: Atomic[Pair[uint64, uint64]]
a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64), moRelease)
