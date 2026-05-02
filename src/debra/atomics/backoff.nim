## debra/atomics/backoff
##
## Spin-loop hint primitives for lock-free retry loops. Two procs:
##
##   * `cpuPause`  - per-CPU spin-loop hint (no syscall, no thread yield).
##                   Tells the CPU to back off cache-coherency traffic
##                   inside a tight retry loop (`pause` on x86/x64,
##                   `yield` on 32-bit ARM and aarch64). Emitted as
##                   inline asm under GCC/Clang and as the matching
##                   `_mm_pause` / `__yield` intrinsic under MSVC.
##                   Compiles to a no-op on architectures or compilers
##                   without an established hint instruction; correctness
##                   is preserved, only micro-efficiency is lost.
##                   Named `cpuPause` (not `cpuRelax`) to avoid collision
##                   with `std/sysatomics.cpuRelax` (re-exported via
##                   `system` unless `-d:nimPreviewSlimSystem`). The
##                   stdlib version is a compiler-barrier-only fallback
##                   on non-x86 (no hardware `yield`/`pause` hint emitted);
##                   this implementation provides the real `yield` hint.
##
##   * `schedYield` - releases the current thread's CPU quantum back to
##                    the OS scheduler. Use when a CAS-retry loop has
##                    spun long enough that the holder is likely
##                    descheduled (oversubscribed runqueue). Maps to
##                    `sched_yield(2)` on POSIX (Linux, macOS, BSDs) and
##                    `SwitchToThread` on Windows. No-op on other targets.
##
## Both procs are `{.inline.}` and have zero overhead when not invoked
## (no per-iteration cost on the success path of a CAS loop).

# Nim normalizes x86_64→amd64 and aarch64→arm64; aliases unnecessary.
# `pause` on i386 is encoded as `rep nop`, safe on pre-SSE2 hardware.
# `yield` on 32-bit ARM (ARMv7+) is encoded as a NOP on older revisions,
# so the same emit is safe across the 32-bit ARM line.
# GCC/Clang/objc-clang use inline-asm; MSVC uses intrinsics from <intrin.h>;
# other backends/compilers fall through to a no-op (correctness preserved,
# only micro-efficiency is lost).
proc cpuPause*() {.inline.} =
  when defined(c) or defined(cpp) or defined(objc):
    when defined(gcc) or defined(clang):
      when defined(amd64) or defined(i386):
        {.emit: """asm volatile("pause" ::: "memory");""".}
      elif defined(arm64) or defined(arm):
        {.emit: """asm volatile("yield" ::: "memory");""".}
      else:
        # Empty asm with "memory" clobber: compiler barrier preventing
        # spin-loop hoisting on archs without a hardware hint (RISC-V,
        # PowerPC, etc). Matches std/sysatomics.cpuRelax fallback semantics.
        {.emit: """asm volatile("" ::: "memory");""".}
    elif defined(vcc):
      when defined(amd64) or defined(i386):
        proc mm_pause() {.importc: "_mm_pause", header: "<intrin.h>".}
        mm_pause()
      elif defined(arm64) or defined(arm):
        proc yield_hint() {.importc: "__yield", header: "<intrin.h>".}
        yield_hint()
      else:
        discard # No MSVC intrinsic for this arch.
    else:
      discard # Unknown C compiler — no portable hint available.
  else:
    discard # No-op on JS or other non-C backends.

proc schedYield*() {.inline.} =
  when defined(posix):
    proc sched_yield(): cint {.importc, header: "<sched.h>".}
    discard sched_yield()
  elif defined(windows):
    proc SwitchToThread(): int32 {.
      importc: "SwitchToThread", stdcall, dynlib: "kernel32"
    .}

    discard SwitchToThread()
  else:
    discard # No-op fallback for non-POSIX, non-Windows targets.
