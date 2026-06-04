## Should-fail fixture: gate 2 (Pair shape) must reject oversized halves.
##
## `Pair[uint32, array[12, byte]]` has 16 bytes of payload (4 + 12) so
## the sum-check passes; but `cmpxchg16b` / `casp` pair two 64-bit
## registers, so neither half may exceed 8 bytes. The per-half assertion
## must catch this independently of the sum-check.
##
## Pinned substring: "must be <= 8 bytes"
import debra/atomics

enforceDwcasConstraints(uint32, array[12, byte])
