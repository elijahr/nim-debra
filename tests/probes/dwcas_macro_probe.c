/*
 * DWCAS cross-compiler macro probe (nim-debra v0.10.0).
 *
 * Empirically probes the compiler macros and runtime CAS behavior that the
 * gate text in src/debra/atomics.nim depends on. Run on each CI cell; diff
 * stdout against tests/probes/dwcas_macro_probe.expected.<runs-on>.<cc> to
 * detect drift in toolchain assumptions.
 *
 * See design §5.2 ("Cross-compiler macro probe") for the four target cells
 * (ubuntu-24.04 gcc/clang, ubuntu-24.04-arm gcc, macos-15 Apple Clang) and
 * the success criterion per cell.
 */
#include <stdio.h>
#include <stdint.h>

typedef struct __attribute__((aligned(16))) { uint64_t a, b; } pair_t;

int main(void) {
#ifdef __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16
    printf("HAVE_SYNC_16=1\n");
#else
    printf("HAVE_SYNC_16=0\n");
#endif
#ifdef __ARM_FEATURE_ATOMICS
    printf("ARM_FEATURE_ATOMICS=1\n");
#else
    printf("ARM_FEATURE_ATOMICS=0\n");
#endif
#ifdef __aarch64__
    printf("AARCH64=1\n");
#else
    printf("AARCH64=0\n");
#endif
    printf("LOCK_FREE_16=%d\n", __atomic_always_lock_free(16, 0));

    pair_t p = {1, 2}, e = {1, 2}, d = {3, 4};
    __int128 ev = *(__int128*)&e, dv = *(__int128*)&d;
    __int128 prev = __sync_val_compare_and_swap((__int128*)&p, ev, dv);
    printf("CAS_OK=%d\n", (prev == ev));
    return 0;
}
