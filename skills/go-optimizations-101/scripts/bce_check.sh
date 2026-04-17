#!/usr/bin/env bash
# Usage: bce_check.sh <pkg>
#   pkg  Go import path or ./... (default: ./...)
#
# Shows surviving bounds checks (ones the compiler could NOT prove safe).
# Each "Found IsInBounds" line = one runtime bounds check still in the binary.
# Each "Found IsSliceInBounds" = surviving slice-bounds check.
# Fewer is better on hot paths — each is a branch + panic path.
set -euo pipefail

pkg="${1:-./...}"

go build -gcflags="-d=ssa/check_bce/debug=1" "$pkg" 2>&1 1>/dev/null \
  | grep -E "Found (IsInBounds|IsSliceInBounds)" \
  | sort -u
