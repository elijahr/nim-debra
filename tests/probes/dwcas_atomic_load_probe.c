/* Empirical probe: does gcc on aarch64 with LSE inline __atomic_load_n
 * for __int128, or fall back to a libatomic call?
 *
 * Compiled with -march=armv8.1-a+lse -mno-outline-atomics; CI step
 * objdump's the result and grep's for either `casp` / `ldp` (inline)
 * or `bl __atomic_load_16` (libcall).
 */
#include <stdint.h>
typedef __int128 i128;

__attribute__((noinline))
i128 probe_load(i128 *p) {
  return __atomic_load_n(p, __ATOMIC_SEQ_CST);
}

__attribute__((noinline))
void probe_store(i128 *p, i128 v) {
  __atomic_store_n(p, v, __ATOMIC_SEQ_CST);
}

int main(void) { return 0; }
