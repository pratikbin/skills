# Bounds-check elimination (BCE)

Go's safety contract: every `s[i]` and `s[a:b]` can panic, so the compiler emits a runtime check. **BCE** is the compiler's ability to prove the check is unneeded and remove it. In tight loops these eliminated checks are worth double-digit percentages.

Diagnostic: `go build -gcflags="-d=ssa/check_bce/debug=1" ./...` — prints one line per **surviving** check. Zero lines = fully BCEed. See `scripts/bce_check.sh`.

## The model

The compiler tracks *facts* about each index/slice operation along every code path. If the facts imply `0 ≤ i < len(s)`, the check is removed.

Facts come from:
- Literal constants.
- `if len(s) >= N { … }` guards.
- Earlier successful index ops (`s[k]` not panicking means `k < len(s)`).
- Induction vars of a `for i := 0; i < len(s); i++`.
- Array type (`[N]T` has a known length).

So the BCE-friendly shapes reduce to: **give the compiler facts, at compile time, about the max index you'll use before you use it.**

## Rules the compiler already handles well (don't overthink)

### Loops on `len(s)`

These **never** produce a bounds check on `s[i]` inside:

```go
for i := range s { _ = s[i]; _ = s[i:len(s)]; _ = s[:i+1] }
for i := 0; i < len(s); i++ { … }
for i := len(s) - 1; i >= 0; i-- { _ = s[i] }
for i := len(s); i > 0; { i--; _ = s[i] }
for i := 0; i < len(s)-1; i += 2 { _ = s[i] }
```

**Pitfall in 1.19**: some of these still keep the *slice* check for `s[:i+1]` — rewrite to index into the slice instead when that specific pattern matters.

### Guarded single-slice access

```go
if len(s) >= 2 {
    r := len(s) % 2
    _ = s[r]            // elided since 1.19
}
```

## Rule 1 — Access the highest index first

Once the compiler sees `s[3]` didn't panic, it knows `len(s) > 3`. Any earlier indexing of `s[0..2]` elides.

```go
// 4 checks
return s[0] | s[1] | s[2] | s[3]

// 1 check
return s[3] | s[0] | s[1] | s[2]
```

This idiom shows up in fixed-width decoders (reading 4-byte integers, fixed headers, etc). Do the bounds-establishing read first.

## Rule 2 — Slice up-front to fix a max length

For a loop `for _, n := range bs { _ = is[n] }` where `n` is a `byte` and `len(is) >= 256`, the compiler can't prove per-iteration that `n < len(is)`. Hint: reslice `is` to exactly 256.

```go
// 1 check per iteration
func f4a(is []int, bs []byte) {
    if len(is) >= 256 {
        for _, n := range bs { _ = is[n] }
    }
}

// 0 checks
func f4b(is []int, bs []byte) {
    if len(is) >= 256 {
        is = is[:256]          // ← hint; slice cap known exactly
        for _, n := range bs { _ = is[n] }
    }
}
```

The forms `_ = is[:256]` and `_ = is[255]` **do not** work as hints in 1.19 — you must bind the result to `is` so subsequent expressions use the narrower slice. Non-rebound hints may work in future versions.

Same pattern for `byte` → `[]int`: `is = is[:256]`.

## Rule 3 — Use a three-index subslice when possible

Between `s[i : i+4]` and `s[i : i+4 : i+4]`, the three-index form emits fewer CPU instructions (see `slices.md` §8.13). It also often BCEs better.

```go
// slowest — 4 IsInBounds in the loop
for i := 0; i < len(s)-3; i += 4 {
    _ = s[i+3]; _ = s[i+2]; _ = s[i+1]; _ = s[i]
}

// faster — 1 IsSliceInBounds per iter
for i := 0; i < len(s)-3; i += 4 {
    s2 := s[i : i+4]
    _ = s2[3]; _ = s2[2]; _ = s2[1]; _ = s2[0]
}

// fastest — 3-index subslice (same BCE; fewer cap-guard instructions)
for i := 0; i < len(s)-3; i += 4 {
    s2 := s[i : i+4 : i+4]
    _ = s2[3]; _ = s2[2]; _ = s2[1]; _ = s2[0]
}

// also fastest — shrink s each iter
for ; len(s) >= 4; s = s[4:] {
    _ = s[3]; _ = s[2]; _ = s[1]; _ = s[0]
}
```

Benchmarks in the book show the middle form can be *slower* than the naive form despite having fewer BCE panics — micro-architectural effects. The 3-index form is the consistent winner.

## Rule 4 — Loop against `len(buf)`, not the constructor argument

```go
// 1 check per iter — compiler doesn't re-derive that i <= n implies i < len(buf)
func f9a(n int) []int {
    buf := make([]int, n+1)
    for i := 0; i <= n; i++ { buf[i] = i }
    return buf
}

// 0 checks
func f9b(n int) []int {
    buf := make([]int, n+1)
    for i := 0; i < len(buf); i++ { buf[i] = i }
    return buf
}
```

When you have a slice, loop against `len(slice)`, not some derived bound. Compiler's facts line up.

## Rule 5 — Copy package-level slices to locals

Package-level (global) slices are BCE-unfriendly because they can be mutated by any goroutine — the compiler conservatively redoes checks.

```go
var s = make([]int, 5)

// 1 check per iter
func fa0() { for i := range s { s[i] = i } }

// 0 checks — local copy is a fresh SSA value compiler can reason about
func fa1() { s := s; for i := range s { s[i] = i } }

// 0 checks — parameter is a local
func fa2(x []int) { for i := range x { x[i] = i } }
```

Pass hot slices as parameters or rebind at the top of the function.

## Rule 6 — Arrays are BCE-friendlier than slices

A `[256]int` has a compile-time known length; a `[]int` of length 256 doesn't. Indexing by `byte` into `[256]T` never has a bounds check.

```go
var a [256]int
func fc2(n byte) int { return a[n] }   // 0 checks

var s = make([]int, 256)
func fc1(n byte) int { return s[n] }   // 1 check
```

If a table is fixed-size and small, use `[N]T`, not `[]T`.

## Rule 7 — Unroll when the inner shape breaks BCE

The compiler sometimes can't prove `i*4 + 3 < len(x)` despite `len(x) == 16` being known. Unrolling removes the index math and yields zero checks:

```go
// 4 checks per iter
func f0a(x [16]byte) (r [4]byte) {
    for i := 0; i < 4; i++ {
        r[i] = x[i*4+3] ^ x[i*4+2] ^ x[i*4+1] ^ x[i*4]
    }
    return
}

// 0 checks, faster
func f0b(x [16]byte) (r [4]byte) {
    r[0] = x[3] ^ x[2] ^ x[1] ^ x[0]
    r[1] = x[7] ^ x[6] ^ x[5] ^ x[4]
    r[2] = x[11] ^ x[10] ^ x[9] ^ x[8]
    r[3] = x[15] ^ x[14] ^ x[13] ^ x[12]
    return
}
```

## Rule 8 — Prefix-equality scan hints

When comparing two strings/slices of potentially-different lengths, a second *redundant* `if len(x) > len(y)` after a swap gives the compiler a refutation it can exploit:

```go
func numSameBytes(x, y string) int {
    if len(x) > len(y) { x, y = y, x }

    // redundant: but gives the compiler the fact len(x) <= len(y)
    if len(x) > len(y) { panic("unreachable") }

    for i := 0; i < len(x); i++ {
        if x[i] != y[i] { return i }  // BCEed on y[i]
    }
    return len(x)
}
```

Variant hints `y = y[:len(x)]` work for slices; `_ = y[:len(x)]` works for strings — but only one each. The `panic("unreachable")` form works for both.

## Known misses in 1.19 (don't try to fix these without a benchmark)

The compiler still fails to BCE:

```go
func fb(s, x, y []byte) {
    n := copy(s, x)
    copy(s[n:], y)    // IsSliceInBounds survives
    _ = x[n:]         // IsSliceInBounds survives
}

func fc(s []byte) {
    const N = 6
    for i := 0; i < len(s)-(N-1); i += N {
        _ = s[i+N-1]  // IsInBounds survives
    }
}

func fd(data []int, check func(int) bool) []int {
    k := 0
    for _, v := range data {
        if check(v) { data[k] = v; k++ }  // IsInBounds survives on data[k]
    }
    return data[:k]                        // IsSliceInBounds survives
}
```

These don't have clean workarounds. Leave them; the compiler will improve.

## Review workflow for BCE

1. Identify the hot loop. Don't waste time BCEing cold code.
2. `scripts/bce_check.sh` for the package.
3. For each surviving check, ask: can I give the compiler a fact?
   - Highest-index-first?
   - `if len(s) >= N { s = s[:N]; … }`?
   - Swap slice for fixed-size array?
   - Local copy instead of package-level access?
   - Unroll?
4. Re-run `bce_check.sh`. Zero surviving checks in the hot loop means you're done with BCE.
5. Benchmark — the wins from BCE are usually small per check but add up in very tight loops. If no measurable win, revert; clarity > cleverness.
