## Should-fail fixture: gate 3 must reject -mno-cx16 on amd64.
##
## Design §8.4: compiling DWCAS with `-mno-cx16` (or otherwise disabling
## the cmpxchg16b instruction) must trip the inline `_Static_assert(
## __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16, ...)` in every DWCAS emit body.
## This catches the silent-fallback failure mode where the C compiler
## would otherwise route 16-byte atomics through a libatomic spinlock.
##
## This fixture is amd64-only AND requires real GCC. On amd64 with
## `-mno-cx16` (set by the companion `.nim.cfg`), the static-assert
## fires; on aarch64 or Apple Clang the `__GCC_HAVE_SYNC_COMPARE_AND_SWAP_16`
## macro is either defined by default (aarch64 with LSE) or not the
## right gate (Apple Clang allows __sync_*_16 without `-mcx16` so the
## fixture cannot be exercised). The runner skips this case off-amd64.
##
## Pinned substring (per design §8.4):
##   "nim-debra DWCAS requires __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16"

import debra/atomics

var a: Atomic[Pair[uint64, uint64]]
a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
discard a.load()
