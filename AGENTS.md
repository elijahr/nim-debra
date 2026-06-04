# AGENTS.md — nim-debra

Project-specific guidance for AI coding agents working on this repo. Loaded by
Claude Code, Codex, OpenCode, etc. at session start; overrides any conflicting
global agent config.

## PR Review Bot

This repo uses **gemini-code-assist[bot]** for PR reviews. NOT styleseatbot,
NOT any other bot the operator's global CLAUDE.md may reference for other
projects.

- Bot username: `gemini-code-assist[bot]`
- Re-review comment: `@gemini-code-assist please re-review`
- Auto-reviews on PR creation: **yes** — the bot fires automatically on PR
  open; on subsequent push cycles, tag explicitly via the re-review comment

If the operator's global config disagrees (e.g., recently updated for a
different project), this file is authoritative for nim-debra.

## Release tagging

Releases are CI-gated, never direct. Standard flow:

1. PR opened against `main` (target branch).
2. PR-dance with gemini-code-assist until clean approval on the LATEST
   commits — any new commit voids prior approval.
3. ALL bot feedback addressed (no out-of-scope hand-waves).
4. CI release workflow tags from `main` post-merge — no developer/agent
   ever runs `git tag vX.Y.Z` directly.

## Build / test conventions

- Nim 2.2.10 minimum (pinned in `debra.nimble`).
- Backends supported: `c`, `cpp` (Linux + macOS); `c` only on Windows MSVC
  (cpp blocked by upstream Nim/MSVC stdlib `/std:c++20` incompatibility).
- Memory managers: arc, orc, refc, atomicArc — all in CI matrix.
- Compilers: GCC, Clang, LLVM-GCC, MSVC (vcc), Nintendo Switch toolchain.

## CI matrix

`.github/workflows/ci.yml` exercises 3 OS (ubuntu-24.04, ubuntu-24.04-arm,
macos-15) × 4 MM × 2 backend on POSIX cells, plus windows-2022 × 4 MM × 1
backend (c-only — cpp upstream-blocked). Plus lint cell.

## Architecture overview (for first-time agents)

- `src/debra/atomics.nim` — custom atomics layer with compile-time lock-free
  guarantees + DWCAS specialization. Wraps `__sync_*` on GCC (16-byte),
  `__atomic_*` on Clang, `_Interlocked*` on MSVC. See `docs/guide/atomics.md`.
- `src/debra/signal.nim` + `src/debra/thread_id.nim` — SMR thread-neutralization
  protocol. POSIX uses SIGUSR1 + sigaction; Windows uses
  SuspendThread/ResumeThread. See `docs/guide/neutralization.md`.
- `src/debra/typestates/` — typestate-tracked critical-section discipline
  built on `nim-typestates`.
- DEBRA+ algorithm per Brown 2017.

## Gotchas for AI agents

- **GCC `__atomic_*_n` at 16 bytes silently calls libatomic** — even with
  `-mcx16` / `-march=armv8.1-a+lse`. Use `__sync_val_compare_and_swap` on
  GCC paths (any arch). CI's objdump regression test catches accidental
  reintroduction (`.github/workflows/ci.yml` libatomic-fallback step).
- **MSVC `_InterlockedCompareExchange128` requires 16-byte aligned
  ComparandResult** — use `__declspec(align(16))` on stack arrays.
- **ARM64 Windows DWCAS** uses `__dmb(_ARM64_BARRIER_SY)`; x64 uses
  `_mm_mfence()` — both wrap the intrinsic for explicit seq_cst.
- **DuplicateHandle leaks** on Windows if not closed — `scanAndSignal` uses
  the non-allocating `isCurrent(tid)` helper to avoid per-iteration leak.
- The atomics module is **C-only emit**; works under both `c` and `cpp`
  Nim backends via `static_assert` (cpp) vs `_Static_assert` (c) gating.

## Upstream Nim issues we depend on

If working on Windows compatibility, check these known upstream bugs first
(linked from `CHANGELOG.md` `### Known Gaps`):

- Nim cpp + MSVC + `/std:c++20`: `const char[N] → char*` errors collide
  with designated-initializer requirements
- Nim orc + Windows: `addToSharedFreeList` SIGSEGV at process teardown
  (cross-thread reclaim path)
