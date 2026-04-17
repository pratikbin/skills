#!/usr/bin/env bash
# Usage: alloc_profile.sh <pkg> <bench-regex>
#   pkg          Go import path (default: ./)
#   bench-regex  passed to -bench (default: .)
#
# Captures an allocation profile from a benchmark and prints the top alloc sites.
# Good first step when allocs/op in -benchmem is not zero and you need to know *where*.
set -euo pipefail

pkg="${1:-./}"
regex="${2:-.}"
prof="$(mktemp -t alloc.XXXXXX.pprof)"

go test -run='^$' -bench="$regex" -benchmem \
  -memprofile "$prof" -memprofilerate=1 "$pkg" > /dev/null

echo "=== top alloc sites (alloc_space) ==="
go tool pprof -top -alloc_space "$prof" | sed -n '1,30p'
echo
echo "Full profile: $prof"
echo "Interactive: go tool pprof -alloc_space $prof"
