# Functions

## 13.1 — Function inlining

The compiler inlines calls to small functions. Inlining saves the call overhead (frame setup, register save/restore) and — more importantly — *feeds escape analysis*: a value that would escape because it's returned from a non-inlined function may stay on the stack when the call is inlined.

### Diagnosing

```
go build -gcflags='-m'            # "can inline X", "inlining call to X"
go build -gcflags='-m=2'          # also: inline costs, reasons for refusal
```

`scripts/inline_report.sh` wraps this.

### What makes a function inline-able (gc 1.19)

- Inline budget: **80** per function.
- Each statement has a cost. When the sum exceeds 80, the compiler refuses.
- **A non-inlined call inside the body costs ~59**, so a function with two non-inlined calls is already over budget.
- Recursive functions: never inlined.
- Functions containing any of these are **never** inlined (1.19):
  - `recover()`
  - a type declaration (`type _ int` inside the body — people use this as an intentional inline blocker)
  - `defer`
  - `go` (launching a goroutine)

### What changed version-to-version

- `for i := 0; i < len(s); i++` — inlineable since 1.16.
- `for i := range s {...}` — inlineable since 1.18. Lower cost than the index form since 1.18.
- `select { case r := <-c: return r }` — inlineable since 1.19.
- Closures — since 1.17.

### Function values that can't be resolved aren't inlined

```go
// package-level variable — compiler doesn't try to resolve it at compile time
var addFunc = add
func main() {
    println(addFunc(11, 22))  // NOT inlined
    var addFunc = add         // local rebind
    println(addFunc(11, 22))  // inlined
}
```

Corollary: `f` from `switch op { case "+": f = add; case "-": f = sub }; return f(a, b)` is not inlineable; the direct-return variant `case "+": return add(a, b)` is.

### `go:noinline` to prevent inlining

```go
//go:noinline
func add(x, y int) int { return x + y }
```

Officially "for toolchain/standard-library use" but it's stable and commonly used in benchmarks, or to make a caller inlineable (see §13.1.5).

### 13.1.4 — Write code in lower-inline-cost ways

Inline cost varies based on seemingly-trivial rewrites. Examples:

```go
// cost 96 — too complex
func foo(x, y int) int {
    a := bar(x, y)
    b := bar(y, x)
    c := bar(a, b)
    d := bar(b, a)
    return c*c + d*d
}

// cost 76 — manually flattened, same math
func foo2(x, y int) int {
    a := x*y - y*y + 2*(x-y)
    b := y*y - x*x + 2*(y-x)
    c := a*a - b*b + 2*(a-b)
    d := b*b - a*a + 2*(b-a)
    return c*c + d*d
}
```

Other small wins:
- **Bare return** (`return` with named results) is cheaper than explicit returns.
- **Named results** at function entry cost 0 (free). Local `var` declarations inside the body cost a little.
- **Combined boolean** (`if a || b || c || d`) is cheaper than multiple `if` branches.
- **Direct calls** in case-body are cheaper than routing through a function value.
- In 1.18+, `for i := range` is cheaper than `for i := 0; i < len(s); i++`.

### 13.1.5 — Make hot paths inlineable by splitting

If a function's slow path puts you over budget, extract the slow path into another function. The hot path stays inlineable.

```go
func concat(bss ...[]byte) []byte {
    if len(bss) == 2 {                    // hot path; kept tiny
        return append(bss[0], bss[1]...)
    }
    return concatSlow(bss...)
}

//go:noinline
func concatSlow(bss ...[]byte) []byte {
    // ... long path; not inlined
}
```

The `//go:noinline` on the slow path is important: if the slow path were inlined into `concat`, the combined cost might again blow the budget. Marking it non-inlineable preserves the hot path's status.

### 13.1.6 — Manual inlining can be faster than auto-inlining

For things the compiler struggles to codegen well (e.g., `*(*[N]byte)(b)` slice-to-array conversion), writing the expression at the call site is faster than calling a helper that does the same thing.

```go
// helper is inlineable but the inlined form is still slower
func Slice2Array(b []byte) [N]byte { return *(*[N]byte)(b) }

// 5.1 ns/op — manual inline at call site
r[i&127] = *(*[N]byte)(buf)

// 11.5 ns/op — auto-inlined helper
r[i&127] = Slice2Array(buf)
```

When you're counting single-digit nanoseconds, copy-paste the body.

### 13.1.7 — Inlining can regress performance

Compiler bugs/quirks. The book shows a case where copying between two package-level `[256]byte` arrays through a non-inlineable function is **faster** than through an inlineable one. If you find a hot function where `//go:noinline` improves the benchmark, that's a valid fix — file a compiler issue but take the win.

## 13.2 — Pointer vs value params/returns

Follows the small-size-type rule from `value-sizes.md`:

| Struct size | Prefer |
|---|---|
| ≤ ~4 word-sized fields | pass/return by value (register ABI; cheaper than pointer) |
| ≥ ~10 word-sized fields | pass/return by pointer |
| 5–9 word-sized fields | benchmark both; compiler may go either way |

Measured:

```
Add5_TT_T (5-float32 struct, value)   17.7 ns/op
Add5_PPP  (5-float32 struct, pointer) 12.0 ns/op

Add4_TT_T (4-float32 struct, value)    2.7 ns/op
Add4_PPP  (4-float32 struct, pointer)  9.0 ns/op
```

4 fields — value wins 3×. 5 fields — pointer wins 1.5×. The cliff matters.

### Caveat — pointer params can introduce escapes

A pointer parameter may force callers to put their value on the heap (if the compiler can't prove the pointer doesn't escape). See `escape-analysis.md`. Benchmark both.

## 13.3 — Named results vs anonymous results

Conventional wisdom: named results are faster (free allocation of the result variable, cheaper bare return). Mostly true — but not always.

- **`copy(ret[:], b); return`** with named result: **faster** than the equivalent unnamed version in the book's `CopyToArray` benchmark (408 vs 547 ns/op).
- **`ret = *(*[N]byte)(b); return`** with named result: **slower** than unnamed (472 vs 333 ns/op).

The second case is an inlining artifact; adding `type _ int` to suppress inlining removes the difference. Moral: **benchmark both** when the function is very short and hot. Don't blindly apply "named results are faster".

## 13.4 — Store intermediate results in locals

Same idea as `pointers.md` §6.2 — compiler sometimes can't prove the pointer/global doesn't alias, so it re-loads and re-stores.

```go
var sum int

// slow — re-loads sum every iteration
func f(s []int) {
    for _, v := range s {
        sum += v
    }
}

// fast — accumulate locally, write once
func g(s []int) {
    n := 0
    for _, v := range s {
        n += v
    }
    sum = n
}
```

Measured:

```
Benchmark_f  3293 ns/op
Benchmark_g   654 ns/op
```

~5× from a single refactor.

## 13.5 — `defer` inside a loop is expensive

`defer` has a per-use cost. In 1.14+ the compiler specially optimizes *open-coded* defers (top-level-in-function); but defers inside loops still pay full cost and also accumulate: each iteration's defer queues another handler to run at function exit, potentially changing semantics (they all run at the end, not per iter).

Fix: wrap the loop body in a closure, so `defer` is top-level within each call.

```go
// 61_797 ns/op (100 iters)
func f(n int) {
    for i := 0; i < n; i++ {
        defer inc()    // queued; all run at f's return
        inc()
    }
}

// 5_990 ns/op (100 iters) — and defer runs per-iteration, which usually matches intent
func g(n int) {
    for i := 0; i < n; i++ {
        func() {
            defer inc()
            inc()
        }()
    }
}
```

~10× faster. **But** the semantics differ — the deferred actions fire per-iteration, not at the end of the outer function. Often that's what you actually wanted anyway. If you really needed batch-at-end, stay with the original form but see if you can move the `defer` out of the loop entirely (e.g., one `defer` that cleans up an accumulator).

## 13.6 — Avoid `defer` entirely in very tight code

Even an open-coded defer costs a few ns. And a function with `defer` is not inlineable (1.19). For the innermost hot loops, unroll the cleanup manually or restructure so the cleanup isn't needed.

## 13.7 — Function arguments always evaluate, even if unused

A conditional-log function doesn't skip argument evaluation. `debugPrint(h + w)` concatenates `h + w` every call, even when `debugOn == false` and `debugPrint` is a no-op.

Idioms:

```go
// 1 — make the flag a constant (dead-code-eliminated)
const debugOn = false

// 2 — short-circuit at the call site
_ = debugOn && debugPrint(h + w)   // debugPrint returns bool

// 3 — accept a closure
debugPrint(func() string { return h + w })   // only called when needed
```

(1) is strongest — no runtime cost at all — but requires a compile-time flag. (2) works for runtime flags but forces `debugPrint` to return `bool`. (3) is cleanest but adds a closure allocation unless the compiler can prove it doesn't escape.

## 13.8 — Don't escape in the hot path

If a function has a hot path that doesn't need its argument on the heap and a cold path that does, split them. In the original:

```go
func f(x int) string {     // x escapes because g(&x) is on cold path
    if x >= 0 && x < 10 {
        return "0123456789"[x : x+1]
    }
    return g(&x)
}
```

`x` escapes for every call — even the hot-path ones that don't take its address. Fix — hoist the escape into the cold branch so the hot branch's `x` stays on the stack:

```go
func f(x int) string {
    if x >= 0 && x < 10 {
        return "0123456789"[x : x+1]
    }
    x2 := x              // only x2 escapes; x stays on stack
    return g(&x2)
}
```

The principle: **escape only in the branch that needs it**. Apply this pattern whenever an argument escapes for a reason that isn't on the hot path.

## Review checklist

- [ ] Hot function not inlined? Check cost with `-m=2`, remove `defer`/closures/recover if possible.
- [ ] Hot function with a slow path? Split so hot path stays under inline budget.
- [ ] Small struct passed by pointer "for performance"? Probably slower than by value. Benchmark.
- [ ] Big struct passed by value in a loop? Switch to pointer or return-sink pattern.
- [ ] Accumulator through `*int` parameter? Use local + final assignment.
- [ ] `defer` in a tight loop? Wrap body in closure or restructure.
- [ ] Hot function escaping a parameter only used on the cold path? Split the escape.
- [ ] Dead-code-like conditional log calling expensive arg builders? Short-circuit at call site or pass a closure.
