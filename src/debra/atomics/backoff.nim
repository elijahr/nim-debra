## debra/atomics/backoff
##
## Spin-loop hint primitives for lock-free retry loops. Two procs:
##
##   * `cpuPause`  - per-CPU spin-loop hint (no syscall, no thread yield).
##                   Tells the CPU to back off cache-coherency traffic
##                   inside a tight retry loop (`pause` on x86, `yield`
##                   on aarch64). Compiles to a no-op on architectures
##                   without an established hint instruction; correctness
##                   is preserved, only micro-efficiency is lost.
##                   Named `cpuPause` (not `cpuRelax`) to avoid collision
##                   with `std/sysatomics.cpuRelax` (re-exported via
##                   `system` unless `-d:nimPreviewSlimSystem`). The
##                   stdlib version is a compiler-barrier-only fallback
##                   on non-x86 (no hardware `yield`/`pause` hint emitted);
##                   this implementation provides the real `yield` hint.
##
##   * `schedYield` - POSIX `sched_yield(2)`. Releases the current
##                    thread's CPU quantum back to the OS scheduler.
##                    Use when a CAS-retry loop has spun long enough
##                    that the holder is likely descheduled (oversubscribed
##                    runqueue). POSIX targets (Linux, macOS, BSDs); see
##                    `when defined(posix)` guard. Windows `SwitchToThread`
##                    is a future item.
##
## Both procs are `{.inline.}` and have zero overhead when not invoked
## (no per-iteration cost on the success path of a CAS loop).

# Nim normalizes x86_64→amd64 and aarch64→arm64; aliases unnecessary.
proc cpuPause*() {.inline.} =
  when defined(amd64):
    {.emit: """asm volatile("pause" ::: "memory");""".}
  elif defined(arm64):
    {.emit: """asm volatile("yield" ::: "memory");""".}
  else:
    discard  # No-op fallback; correctness preserved.

proc schedYield*() {.inline.} =
  when defined(posix):
    proc sched_yield(): cint {.importc, header: "<sched.h>".}
    discard sched_yield()
  else:
    discard  # No-op fallback for non-POSIX targets.
