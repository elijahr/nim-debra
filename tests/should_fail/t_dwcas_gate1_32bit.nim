## Should-fail fixture: gate 1 (64-bit target requirement) must
## reject DWCAS / 16-byte atomics on 32-bit ABIs.
##
## `Pair[uint64, uint64]` itself is a well-formed object on any
## target (it's just a struct). `enforceDwcasConstraints(uint64,
## uint64)` is the gate that asserts `sizeof(pointer) == 8` — on a
## 32-bit ABI (--cpu:i386 / --cpu:i686 cross-compile) this assert
## fails at compile time with the canonical error message.
##
## The check fires via the size-16 op specializations (load, store,
## exchange, compareExchange*) which sit inside `when sizeof(pointer)
## == 8:` AND call `enforceDwcasConstraints` themselves. Invoking the
## template directly is the most surgical way to exercise gate 1
## without dragging in the op surface (which would error first with
## "undeclared identifier" on 32-bit, masking the intended diagnostic).
##
## Pinned substring: "require a 64-bit target"
import debra/atomics

enforceDwcasConstraints(uint64, uint64)
