#!/usr/bin/env bash
# Doc-comment audit for src/debra/atomics.nim public DWCAS surface.
#
# Fails the build if any public `proc` or `template` whose name suggests
# DWCAS coverage (or which lives inside the `when sizeof(pointer) == 8:`
# DWCAS specialization block) lacks an immediately-following `##`
# doc-comment line.
#
# Heuristic: scan src/debra/atomics.nim, find every line matching
# `^[[:space:]]*(proc|template) [a-zA-Z]+\*` (i.e. an exported public
# definition), then look at the next ~6 lines for a `##` line. The
# 6-line window accommodates multi-line signatures with one-arg-per-line
# formatting that nph produces.
#
# Exit 0 if every public proc/template has at least one `##` line in
# its signature/body. Exit 1 with a list of undocumented symbols
# otherwise.
#
# Release-blocking: run from .github/workflows/docs.yml before the
# mkdocs build step.

set -euo pipefail

SRC="${1:-src/debra/atomics.nim}"

if [[ ! -f "$SRC" ]]; then
  echo "audit: source file not found: $SRC" >&2
  exit 2
fi

missing=()

# Locate the start of the DWCAS specialization block. The block opens with
# the second occurrence of `^when sizeof(pointer) == 8:` in the file (the
# first occurrence on line 219ish is the gate-1 error-out block; the
# second is the DWCAS-op specialization block).
dwcas_start=$(grep -n '^when sizeof(pointer) == 8:' "$SRC" | sed -n '2p' | cut -d: -f1)
if [[ -z "$dwcas_start" ]]; then
  echo "audit: failed to locate DWCAS specialization block start in $SRC" >&2
  exit 2
fi

# Extract line numbers of all exported procs/templates inside the DWCAS
# specialization block (lines >= dwcas_start).
mapfile -t def_lines < <(
  awk -v start="$dwcas_start" '
    NR >= start && /^[[:space:]]*(proc|template) [a-zA-Z]+\*/ { print NR }
  ' "$SRC"
)

for ln in "${def_lines[@]}"; do
  # Look 1..12 lines forward for a `##` doc-comment line. The window has to
  # be wide enough to cover multi-line signatures (one arg per line) before
  # the body starts.
  end=$((ln + 12))
  if awk -v a="$ln" -v b="$end" 'NR>=a && NR<=b && /^[[:space:]]*##/ { found=1; exit } END { exit !found }' "$SRC"; then
    continue
  fi
  # No `##` found within window — record signature line for the report.
  sig=$(awk -v n="$ln" 'NR==n { print; exit }' "$SRC")
  missing+=("$SRC:$ln: $sig")
done

if (( ${#missing[@]} > 0 )); then
  echo "audit: ${#missing[@]} public proc/template(s) in $SRC lack a doc-comment:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

count=${#def_lines[@]}
echo "audit: $count public proc/template(s) in $SRC all carry doc-comments. OK."
