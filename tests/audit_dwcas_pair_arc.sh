#!/usr/bin/env bash
# tests/audit_dwcas_pair_arc.sh
#
# F2 closure audit (impl plan Task 15, design §2.6, HIGH-2):
# Pair[uint64, ptr T] DWCAS must NOT generate `=destroy` / `=copy` hooks
# on Pair. Any such hook either touches the pointee (lifetime claim we
# explicitly disclaim) or inserts ARC traffic into the DWCAS hot path.
#
# Compiles tests/test_dwcas_pair_ptr.nim with `--expandArc:auditDwcasPtrProc`
# under --mm:arc and greps the expansion for any `=destroy` / `=copy`
# invocation mentioning Pair.
#
# Exit 0: ZERO matches (F2 invariant holds).
# Exit 1: any match (regression — ships F2 unverified).

set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

out="$(nim c --mm:arc --threads:on --path:src -d:testing --hints:off \
  --warnings:off --expandArc:auditDwcasPtrProc -c \
  tests/test_dwcas_pair_ptr.nim 2>&1)"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "FAIL [Task 15]: --expandArc compile failed (rc=$rc):"
  printf '%s\n' "$out"
  exit 1
fi

# Pinned acceptance per impl plan Task 15: grep count for ARC hooks on
# Pair must equal zero. Match a few common spellings the compiler may emit:
#   `=destroy(...Pair_...)`  /  `=copy(...Pair_...)`
#   `=destroy_Pair_...`       /  `=copy_Pair_...`
# Use extended regex to cover both forms.
hook_count=$(printf '%s\n' "$out" | grep -cE '=destroy.*Pair|=copy.*Pair' || true)

if [ "$hook_count" -ne 0 ]; then
  echo "FAIL [Task 15]: $hook_count ARC hook reference(s) on Pair in expanded output:"
  printf '%s\n' "$out" | grep -E '=destroy.*Pair|=copy.*Pair'
  echo ""
  echo "F2 closure broken: Pair[uint64, ptr int] must have zero =destroy/=copy hooks."
  exit 1
fi

echo "PASS [Task 15]: zero =destroy/=copy hooks on Pair in --expandArc output"
exit 0
