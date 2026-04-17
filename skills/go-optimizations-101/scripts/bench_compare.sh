#!/usr/bin/env bash
# Usage: bench_compare.sh <pkg> <bench-regex> [count]
#   pkg          Go import path (default: ./)
#   bench-regex  passed to -bench (default: .)
#   count        -count value for each run (default: 10)
#
# Workflow:
#   1. Run this on your CURRENT code          -> writes old.txt
#   2. Make your optimization                 -> code change
#   3. Run this again                         -> writes new.txt and diffs with benchstat
#
# Requires: go install golang.org/x/perf/cmd/benchstat@latest
set -euo pipefail

pkg="${1:-./}"
regex="${2:-.}"
count="${3:-10}"

run() {
  local out=$1
  go test -run='^$' -bench="$regex" -benchmem -count="$count" "$pkg" | tee "$out"
}

if [[ ! -f old.txt ]]; then
  echo "→ No old.txt found. Writing baseline to old.txt. Re-run after your change."
  run old.txt
  exit 0
fi

echo "→ old.txt exists. Writing current run to new.txt and diffing."
run new.txt
echo
echo "=== benchstat old.txt new.txt ==="
if command -v benchstat >/dev/null 2>&1; then
  benchstat old.txt new.txt
else
  echo "benchstat not installed. Install with:"
  echo "  go install golang.org/x/perf/cmd/benchstat@latest"
fi
