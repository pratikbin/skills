#!/usr/bin/env bash
# Usage: inline_report.sh <pkg> [name-regex]
#   pkg         Go import path or ./... (default: ./...)
#   name-regex  only show functions whose name matches this (default: all)
#
# Shows which functions were inlined and which were rejected, with the reason
# (e.g. "function too complex", "call to runtime.*", "leaf call", "unhandled op DEFER").
set -euo pipefail

pkg="${1:-./...}"
name_regex="${2:-}"

out="$(go build -gcflags='-m=2' "$pkg" 2>&1 1>/dev/null || true)"

{
  echo "## Inlined"
  echo "$out" | grep -E "can inline|inlining call to" | sort -u
  echo
  echo "## NOT inlined (with reason)"
  echo "$out" | grep -E "cannot inline|function too complex|leaking param" | sort -u
} | { if [[ -n "$name_regex" ]]; then grep -E "$name_regex"; else cat; fi; }
