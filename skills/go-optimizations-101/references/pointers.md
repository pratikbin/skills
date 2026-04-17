# Pointers in hot loops

Two specific compiler gaps (gc 1.19) that are worth knowing when tuning a loop.

## 1. Nil array-pointer checks get repeated every iteration

The compiler generates a nil check on a `*[N]T` argument but — as of 1.19 — sometimes fails to hoist that check out of a loop that uses `a[i]`.

Slow (nil check inside the loop):

```go
func g0(a *[N]int) {
    for i := range a {
        a[i] = i   // TESTB emitted per iteration
    }
}
```

Fast (nil check once, hoisted):

```go
func g1(a *[N]int) {
    _ = *a                 // forces one early nil-check
    for i := range a {
        a[i] = i
    }
}

// or even better — slices are optimized more aggressively:
func g2(a *[N]int) {
    s := a[:]              // derive slice, same backing
    for i := range s {
        s[i] = i
    }
}
```

Measured (N=1000):

```
Benchmark_g0   517.6 ns/op
Benchmark_g1   398.1 ns/op
```

### When the pointer is a struct field, the simple trick doesn't work

`_ = *t.a` before the loop does **not** hoist the check, because each `t.a` inside the loop is a fresh field load whose result could differ. Copy `t.a` to a local first.

```go
type T struct{ a *[N]int }

// slow — nil check each iter
func f0(t *T) {
    for i := range t.a { t.a[i] = i }
}

// copy to local then hoist
func f3(t *T) {
    a := t.a
    _ = *a
    for i := range a { a[i] = i }
}

// preferred: derive a slice
func f4(t *T) {
    a := t.a[:]
    for i := range a { a[i] = i }
}
```

Measured:

```
f0  622.9 ns/op
f1  637.4 ns/op   // _ = *t.a does nothing useful
f2  511.3 ns/op   // just local-copy, no early deref
f3  390.1 ns/op   // local-copy + early deref
f4  387.6 ns/op   // slice
```

**Rule:** when you have `*[N]T` coming from a field or through multiple indirections, copy it to a local (or convert to a slice with `x[:]`) once, then use the local in the loop.

## 2. A dereferenced pointer inside a loop keeps re-reading memory

If you sum into `*p` in a loop, the compiler sometimes can't prove the loop body doesn't alias `p`, so it re-loads and re-stores memory every iteration.

Slow (~5× slower):

```go
//go:noinline
func f(sum *int, s []int) {
    for _, v := range s {
        *sum += v   // load, add, store to memory each iter
    }
}
```

Fast (accumulate in a local, write once at the end):

```go
//go:noinline
func g(sum *int, s []int) {
    n := *sum
    for _, v := range s {
        n += v      // register-only
    }
    *sum = n
}
```

Measured (s has 1024 ints):

```
Benchmark_f   3024 ns/op
Benchmark_g    566 ns/op
```

### Caveat — this is **not** a pure optimization

`f` and `g` are not semantically equivalent when `sum` aliases an element of `s`:

```go
s := []int{1, 1, 1}
sum := &s[2]
f(sum, s) // *sum = 6  — because each *sum += v re-reads s[2]
g(sum, s) // *sum = 4  — because the local accumulator is isolated
```

Use the local-accumulator pattern only when you know `sum` doesn't alias anything in the slice. Better yet, let the function return the sum and let the caller assign:

```go
func h(s []int) int {
    n := 0
    for _, v := range s { n += v }
    return n
}
```

## Review heuristic

When you see a pointer-dereference or a `*[N]T` accessed inside a loop body, ask:
1. Can we hoist the dereference to a local outside the loop?
2. Can we convert the pointer-to-array to a slice once?
3. If the pointer is an output (accumulator), are we OK with it not being live-updated per-iteration? If yes, accumulate locally and write once.

Apply the transforms and verify with `scripts/bench_compare.sh`. The wins here are large when they exist and zero when they don't — measure.
