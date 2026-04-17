# Escape analysis & stack allocation

## The core rule

A value allocated on the **stack** is free (well, ~free). A value that **escapes to the heap** costs an allocation *and* contributes to GC pressure. The compiler tries to stack-allocate when it can prove it's safe — that's escape analysis.

Proof requirement: the value is used only by its goroutine, only for the lifetime of its containing function call (or is inlined into one where the same holds), and isn't captured by anything with a longer lifetime.

When the compiler can't prove that, it conservatively chooses the heap. "Proof" is expensive, so the compiler sometimes gives up on value shapes that actually would be safe. That's where this reference earns its keep — it tells you which code shapes force escape and how to rewrite them.

**See the analysis output:** `go build -gcflags='-m=2'` (more `-m`s = more detail, up to `-m=4`). Use `scripts/escape_analysis.sh` to filter out noise.

## Stack mechanics (just enough to reason)

- Each goroutine has a stack. Initial size 2 KiB (1.19+). Stack grows in powers of 2, up to ~512 MiB on 64-bit systems.
- A function's **stack frame size** is fixed at compile time — it's the max of all reachable value sizes inside it. Including branches that never execute. Printed by `go build -gcflags=-S`.
- Stacks grow by allocating a bigger contiguous region and copying the live part. Pointers to stack memory are rewritten during the copy.
- Stacks shrink during GC cycles if usage is ≤ ¼ of the current size. Each shrink halves the stack.
- **Frequent growth is costly.** Allocating a huge value on stack can defeat the whole point.

## Package-level values always escape

Every `var` at package scope is heap-allocated. If you assign the address of a local to a package-level variable, the local escapes too. This is by design — lifetime is unbounded.

## Reasons a local escapes, with fixes

These are the cases the book catalogs. Most of them come up in real code.

### 1. Captured by a closure that outlives the frame

If a `go func() { use(&x) }()` runs a goroutine that might outlive the caller, `x` escapes. Even if it doesn't actually — the compiler usually can't prove lifetime.

**Mitigation:** pass copies into the goroutine; the closure captures no pointer.

```go
// escapes: a, b
var a = 1
var b = false
go func() {
    if b { a++ }       // closure captures &a, &b
}()

// does not escape: pass a and b by value
a := 1
b := false
go func(a int, b bool) {
    if b { a++ }
}(a, b)
```

### 2. Address of a loop-local variable stored outside the loop

Even if the loop executes exactly once, the compiler conservatively assumes there may be many co-existing instances of `n`, so each instance goes to the heap.

```go
var x *int
for {
    var n = 1    // moved to heap: n
    x = &n
    break
}
_ = x
```

Fix: hoist the variable out of the loop when feasible.

### 3. Pointer passed to an **interface** method call

Arguments to a dynamically-dispatched method call escape because the compiler usually can't see the concrete implementation.

```go
type I interface{ M(*int) }
type T struct{}
func (T) M(*int) {}

var t T
var i I = t

var x int; t.M(&x)   // does NOT escape (static call)
var y int; i.M(&y)   // escapes (dynamic call)
```

Fix: call the concrete type directly when you have it; drop the interface from hot paths; see `references/interfaces.md` §14.4.

**Exception:** if the compiler can **de-virtualize** the call (trivial case, obvious concrete type), it may prove non-escape.

### 4. `reflect.ValueOf(x)` and friends

`reflect.ValueOf` forces `x` to the heap as of 1.19. Even `reflect.ValueOf(k)` — a non-pointer — causes the *copy* of `k` to escape.

Consequences:
- `fmt.Println(&x)` — the entire `fmt` package internally calls `reflect.ValueOf`. Every argument escapes.
- Use `println(&y)` (builtin) for hot-path tracing — it does not escape its args.

```go
var x = 1
fmt.Println(&x)   // moved to heap: x
var y = 2
println(&y)       // does not escape
```

### 5. Pointer returned from a function

Return values and anything they transitively reference escape (because the caller may stash them). Unless the call is **inlined**, in which case the returned pointer becomes a local in the caller and escape analysis can see the whole picture.

```go
//go:noinline
func f(x *int) *int {
    var n = *x + 1  // moved to heap: n
    return &n
}
```

Remove `//go:noinline` and `n` stays on the stack (the call gets inlined into `main`, and the compiler can see nothing captures `&n`).

### 6. Inlining affects escape — but not always helpfully

Inlining **can** move escapes onto the stack. But not when the compiler fails to propagate constants or flow information through the inlined call. Example where inlining doesn't help:

```go
func createSlice(n int) []byte { return make([]byte, n) }

func main() {
    x := createSlice(32)      // escapes even after inline (constant doesn't propagate)
    y := make([]byte, 32)     // stack-allocated
    _, _ = x, y
}
```

This is a known compiler gap; it may improve in future Go versions.

## Size thresholds (Go 1.19)

Even when provably safe to stack-allocate, the compiler avoids stacking anything too big (to stop stack growth from exploding).

| Construct | Threshold above which it escapes |
|---|---|
| `string(b)` / `[]byte(s)` result bytes | > 32 bytes (relaxed to 64 KiB for constant strings) |
| `new(T)` / `&T{}` | `sizeof(T) > 64 KiB` |
| `make([]T, N)` — `N` **constant** | `N * sizeof(T) > 64 KiB` |
| `make([]T, n)` — `n` **non-constant** | always escapes if `n > 0` |
| `var x [N]T` (direct part of var decl) | `N * sizeof(T) > 10 MiB` |

Under `-gcflags=-smallframes`, the 64 KiB → 16 KiB and 10 MiB → 128 KiB.

## Tricks to keep big backing arrays on the stack

Use with care — these are corner cases that may tighten in future Go versions.

1. **Derive a slice from a stack array.** The array is a `[N]T` var decl (10 MiB limit), and slicing it produces a stack-backed slice of any length you want, up to that limit.

    ```go
    const N = 10 * 1024 * 1024
    var a [N]byte      // stack — var decl, under 10 MiB
    s := a[:]           // still stack-backed
    ```

2. **Use a composite literal**, not `make`. As of 1.19, `[]byte{N: 0}` doesn't escape regardless of `N`. The book documents a 500 MiB case that stayed on the stack.

    ```go
    s := []byte{N: 0}   // stack — even if N is huge (as of 1.19)
    ```

3. **Misc corner cases** that also stay on the stack (but you wouldn't write these for performance — all three are slow in other ways):
   - Large value boxed into an interface inside a non-inlineable function.
   - Large value as a function parameter (but the copy cost is awful).
   - Large value assigned into a map (copy cost again).

The book is clear: if you find yourself using these tricks, consider whether your algorithm shape is the actual problem.

## Pre-grow the stack to avoid repeated grow-and-copy

If you can predict that a goroutine's stack will eventually hit N bytes, pre-grow it with a dummy function that "needs" a large frame. The body of the function doesn't run (`if x != nil` when `x` is nil), but the compiler allocates the frame for it before proving it's unreachable.

```go
func bar(c chan time.Duration) {
    start := time.Now()
    func(x *interface{}) {
        type _ int                          // prevents inlining
        if x != nil {
            *x = [1024 * 1024 * 64]byte{}   // forces frame size
        }
    }(nil)
    demo(8192)
    c <- time.Since(start)
}
```

Measured: `foo` (no pre-grow) 42 ms vs `bar` (pre-grow) 4.7 ms for the same deep recursion.

Only useful for very long-lived goroutines with predictable peak depth. Ordinary code doesn't need this.

## Explicitly force a value onto the heap

Rare. The idiom used by the standard library internals:

```go
var sink any

func escape(x any) {
    if x == nil {
        escape(&x)           // self-referential call, so inliner gives up
        panic("x must not be nil")
    }
    sink = x
    sink = nil
}
```

Call `escape(&v)` to guarantee `v` escapes. The `sink = x; sink = nil` is DCE-visible but still affects escape analysis.

## Explicitly keep a value on the stack

Copy the value locally, then use the copy:

```go
// Original: 'a' and 'b' escape because the goroutine captures them.
b1 := b                          // local copy
go func(a int) {                 // pass by value
    if b1 { a++; c <- a }
}(a)
```

## Diagnostic workflow

1. `scripts/escape_analysis.sh ./pkg` — enumerate "escapes to heap" / "moved to heap" lines.
2. For each escape, ask: does the escape have to happen? Walk the list above.
3. Apply a fix, re-run the script, confirm the line is gone.
4. `go test -bench -benchmem` — confirm `allocs/op` decreased.
5. Avoid the trap: compiler messages say "X does not escape" — that means **the compiler proved safety**. If size thresholds are hit, X still goes to the heap. Check the alloc benchmark, not just the escape output.
