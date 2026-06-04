# DWCAS macro probe

`dwcas_macro_probe.c` is a small standalone C program (no dependencies
beyond `<stdio.h>` / `<stdint.h>`) that fingerprints the compiler
macros and runtime CAS behavior nim-debra's DWCAS gate text relies on.

It is compiled and run by CI on each cell of the test matrix; the
stdout is diffed against the matching `dwcas_macro_probe.expected.<cell>`
golden. Drift fails the build by design — any toolchain change that
shifts the fingerprint forces a conscious update of the golden in a
commit that names the cause.

## Files

| File | Cell | Compiler / flags |
|------|------|---|
| `dwcas_macro_probe.c` | source | (same on all cells) |
| `dwcas_macro_probe.expected.ubuntu-24.04.gcc` | ubuntu-24.04 | gcc + `-mcx16` |
| `dwcas_macro_probe.expected.ubuntu-24.04.clang` | ubuntu-24.04 | clang + `-mcx16` |
| `dwcas_macro_probe.expected.ubuntu-24.04-arm` | ubuntu-24.04-arm | gcc + `-march=armv8.1-a+lse -mno-outline-atomics` |
| `dwcas_macro_probe.expected.macos-15` | macos-15 | Apple Clang (no extra flag — LSE default on Apple Silicon) |

## Golden provenance

- `dwcas_macro_probe.expected.macos-15` was generated empirically from
  the dev machine (macos-15 / Apple Silicon / Apple Clang). It is the
  canonical expectation for that cell.
- The three remaining goldens (`ubuntu-24.04.gcc`, `ubuntu-24.04.clang`,
  `ubuntu-24.04-arm`) are seeded from design §5.2 documented
  expectations. **CI's first run on each cell verifies them.** If CI
  flags drift on first run, the operator must:
  1. Confirm the drift is intentional (toolchain version bump, runner
     image update, new flag inferred).
  2. `git diff` review the new golden content.
  3. Commit the update with a message that names the cause
     (e.g. `update probe golden for ubuntu-24.04 GCC 14 → 15 upgrade`).

This matches the Phase A.5 golden-file checkin protocol in design §5.2.5.
