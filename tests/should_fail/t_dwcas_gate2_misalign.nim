## Should-fail fixture: gate 2 (Pair shape) must reject undersized halves.
##
## `Pair[uint64, uint32]` has only 12 bytes of payload (8 + 4); the
## remaining 4 bytes are padding inserted by the field-level
## `{.align: 16.}` on `first`. The DWCAS shape gate must catch this
## because `cmpxchg16b` / `casp` requires both halves to be live (no
## indeterminate padding bits in the comparand).
##
## Pinned substring: "must be exactly 16 bytes"
import debra/atomics

enforceDwcasConstraints(uint64, uint32)
