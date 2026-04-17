#!/usr/bin/env bash
# Usage: escape_analysis.sh <pkg> [filter]
#   pkg    Go import path or ./... (default: ./...)
#   filter grep pattern to narrow results (default: "escapes to heap|moved to heap|does not escape")
#
# Prints the compiler's escape-analysis decisions so you can see *where* and *why*
# values escape to the heap. Uses -m=2 for the full reason chain.
set -euo pipefail

pkg="${1:-./...}"
filter="${2:-escapes to heap|moved to heap|does not escape}"

# stderr carries the -m diagnostics; redirect to stdout so grep can see them.
# -l=0 disables inlining to get unmasked escape results (inlining can mask escapes).
go build -gcflags='-m=2 -l=0' "$pkg" 2>&1 1>/dev/null \
  | grep -E "$filter" \
  | sort -u
