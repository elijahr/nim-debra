#!/usr/bin/env bash
# DWCAS warning-emission and silencer-suppression check (impl plan Tasks 18, 19).
#
# Compiles two fixtures under `--warning[User]:on` and inspects nim's stderr:
#   * t_dwcas_warning.nim     -- MUST emit the seq_cst-upgrade warning
#   * t_dwcas_silenced.nim    -- MUST NOT emit it (wrapped in dwcasOrderRelaxedCAS)
#
# Exit code 0 = both assertions hold. Non-zero on any failure. Runs from
# the repo root (the worktree root).

set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

warn_substr='nim-debra DWCAS upgrades memory order to moSequentiallyConsistent'

fail=0

# --- Task 18: warning MUST fire on unwrapped sub-seq_cst order ---
emit_out="$(nim c --path:src --threads:on -d:testing --hints:off \
  --warning[User]:on -f -c tests/compile_only/t_dwcas_warning.nim 2>&1)"
emit_rc=$?
if [ "$emit_rc" -ne 0 ]; then
  echo "FAIL [Task 18]: fixture compile failed (rc=$emit_rc):"
  printf '%s\n' "$emit_out"
  fail=1
elif printf '%s\n' "$emit_out" | grep -F -q "$warn_substr"; then
  echo "PASS [Task 18]: warning emitted on unwrapped sub-seq_cst order"
else
  echo "FAIL [Task 18]: expected warning substring not found in stderr:"
  echo "  expected: $warn_substr"
  echo "  actual:"
  printf '%s\n' "$emit_out"
  fail=1
fi

# --- Task 19: warning MUST NOT fire when wrapped in dwcasOrderRelaxedCAS ---
silenced_out="$(nim c --path:src --threads:on -d:testing --hints:off \
  --warning[User]:on -f -c tests/compile_only/t_dwcas_silenced.nim 2>&1)"
silenced_rc=$?
if [ "$silenced_rc" -ne 0 ]; then
  echo "FAIL [Task 19]: fixture compile failed (rc=$silenced_rc):"
  printf '%s\n' "$silenced_out"
  fail=1
elif printf '%s\n' "$silenced_out" | grep -F -q "$warn_substr"; then
  echo "FAIL [Task 19]: warning leaked from dwcasOrderRelaxedCAS-wrapped site:"
  printf '%s\n' "$silenced_out"
  fail=1
else
  echo "PASS [Task 19]: warning suppressed inside dwcasOrderRelaxedCAS"
fi

exit "$fail"
