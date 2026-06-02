## Driver for nim-debra's compile-fail test suite.
##
## Each entry asserts (a) the expected exit status from `nim c` (zero
## for positive cases, non-zero for negative cases) and (b) that the
## compiler's combined stdout+stderr contains a pinned error-message
## substring specific to the failure mode under test.
##
## Pinning the substring (rather than just the exit status) guards
## against silent regressions where the compile-fail still happens but
## the underlying check has rotted — e.g., a future typestates release
## that drops the CFG-analyzer terminal-not-reached gate, or a Nim
## release that renames the `=copy` error template.
##
## The CFG-analyzer negative test uses a local-fixture typestate
## (MyFSM) because typestates 0.9.2 only walks `{.transition.}`-
## registered procs, and `{.transition.}` must live in the
## typestate's home module. The fixture's home module IS the test
## file, so the analyzer walks `badEarlyReturn` and rejects it.
## This guards against future typestates releases weakening the
## CFG-analyzer soundness gate (analyzer removed, substring rotated,
## walk-coverage shrunk).

import std/[os, osproc, strformat, strutils]

type
  ExpectedOutcome = enum
    eoCompiles # `nim c` must exit 0; no substring needed.
    eoCompileFails # `nim c` must exit non-zero; substring must appear.

  ArchGate = enum
    agAny # Runs on every arch (default).
    agAmd64Gcc
      # amd64 only AND real GCC (Apple Clang allows __sync_*_16
      # without -mcx16 so the fixture cannot be exercised).

  Case = object
    name: string
    file: string
    outcome: ExpectedOutcome
    substring: string
    archGate: ArchGate

const cases = @[
  Case(
    name: "cfg-terminal-not-reached positive (must compile)",
    file: "tests/should_fail/cfg_terminal_not_reached_positive.nim",
    outcome: eoCompiles,
    substring: "",
  ),
  Case(
    name: "cfg-terminal-not-reached negative (must fail-with-substring)",
    file: "tests/should_fail/cfg_terminal_not_reached_negative.nim",
    outcome: eoCompileFails,
    substring: "has not reached a terminal state at this return",
  ),
  Case(
    name: "pinned-scope =copy (must fail-with-substring)",
    file: "tests/should_fail/t_pinned_scope_copy.nim",
    outcome: eoCompileFails,
    substring: "'=copy' is not available for type",
  ),
  Case(
    name: "retireOnCAS non-pointer T rejected (must fail-with-substring)",
    file: "tests/should_fail/t_retire_nonptr_rejected.nim",
    outcome: eoCompileFails,
    substring: "T: ptr | pointer",
  ),
  Case(
    name: "DWCAS gate 2: undersized Pair halves rejected (must fail-with-substring)",
    file: "tests/should_fail/t_dwcas_gate2_misalign.nim",
    outcome: eoCompileFails,
    substring: "must be exactly 16 bytes",
  ),
  Case(
    name: "DWCAS gate 2: oversized Pair half rejected (must fail-with-substring)",
    file: "tests/should_fail/t_dwcas_gate2_halfsize.nim",
    outcome: eoCompileFails,
    substring: "must be <= 8 bytes",
  ),
  Case(
    name: "DWCAS load rejects moRelease (must fail-with-substring)",
    file: "tests/should_fail/t_dwcas_load_moRelease.nim",
    outcome: eoCompileFails,
    substring: "moRelease / moAcquireRelease is not a valid memory order for load",
  ),
  Case(
    name: "DWCAS store rejects moAcquire (must fail-with-substring)",
    file: "tests/should_fail/t_dwcas_store_moAcquire.nim",
    outcome: eoCompileFails,
    substring: "moAcquire / moAcquireRelease / moConsume is not a valid",
  ),
  Case(
    name: "DWCAS CAS rejects failure-order moRelease (must fail-with-substring)",
    file: "tests/should_fail/t_dwcas_cas_failure_moRelease.nim",
    outcome: eoCompileFails,
    substring: "compareExchange failure order",
  ),
  Case(
    name:
      "DWCAS gate 3: -mno-cx16 trips inline _Static_assert " &
      "(must fail-with-substring, amd64+GCC only)",
    file: "tests/should_fail/t_dwcas_no_mcx16.nim",
    outcome: eoCompileFails,
    substring: "nim-debra DWCAS requires __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16",
    archGate: agAmd64Gcc,
  ),
]

proc detectHostArch(): string =
  ## Returns "amd64", "arm64", or whatever `uname -m` reports normalized.
  let (uname, rc) = execCmdEx("uname -m")
  if rc != 0:
    return "unknown"
  let s = uname.strip()
  case s
  of "x86_64", "amd64": "amd64"
  of "arm64", "aarch64": "arm64"
  else: s

proc detectIsRealGcc(): bool =
  ## True only if `cc --version` reports GNU GCC (not Apple Clang or
  ## llvm-clang). Apple Clang's banner starts with "Apple clang"; real
  ## GCC's banner contains "gcc (GCC)" or "Free Software Foundation".
  let (banner, rc) = execCmdEx("cc --version")
  if rc != 0:
    return false
  let s = banner.toLowerAscii()
  result = ("gcc" in s) and ("clang" notin s)

proc shouldSkip(c: Case): bool =
  case c.archGate
  of agAny:
    false
  of agAmd64Gcc:
    let arch = detectHostArch()
    let gcc = detectIsRealGcc()
    not (arch == "amd64" and gcc)

proc runCase(c: Case): bool =
  let cmd =
    &"nim c --threads:on --hints:off --warnings:off --path:src --compileOnly {c.file}"
  let (output, exitCode) = execCmdEx(cmd)
  case c.outcome
  of eoCompiles:
    if exitCode != 0:
      echo &"[FAIL] {c.name}: expected exit 0, got {exitCode}"
      echo output
      return false
    echo &"[PASS] {c.name}"
    return true
  of eoCompileFails:
    if exitCode == 0:
      echo &"[FAIL] {c.name}: expected non-zero exit, got 0 (unexpected success)"
      echo output
      return false
    if not output.contains(c.substring):
      echo &"[FAIL] {c.name}: substring not found"
      echo &"       expected substring: {c.substring}"
      echo "       actual output:"
      echo output
      return false
    echo &"[PASS] {c.name} (exit {exitCode}, substring matched)"
    return true

proc main() =
  var failed = 0
  var skipped = 0
  for c in cases:
    if shouldSkip(c):
      echo &"[SKIP] {c.name} (archGate={c.archGate}, host arch/cc mismatch)"
      inc skipped
      continue
    if not runCase(c):
      inc failed
  if failed > 0:
    echo &"\n{failed} compile-fail case(s) failed."
    quit(1)
  echo &"\nAll {cases.len - skipped} compile-fail cases passed " &
    &"({skipped} skipped by archGate)."

main()
