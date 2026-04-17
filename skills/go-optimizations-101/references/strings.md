# Strings and byte slices

Strings are immutable `[]byte` views. Converting `string ↔ []byte` normally copies the bytes (to preserve immutability). The compiler has several **allocation-elision rules** that matter enormously for hot code.

## 9.1.1 — `for _, b := range []byte(s)` does NOT allocate

The compiler sees the conversion is only consumed by the range, so it ranges over the string's bytes directly.

```go
// identical performance:
for i, b := range []byte(s) { ... }
for i := 0; i < len(s); i++ { b := s[i]; ... }
```

## 9.1.2 — `string(b)` as a comparison operand does NOT allocate

These don't allocate:

```go
bytes.Equal(a, b []byte) bool {
    return string(a) == string(b)
}

// Equivalent pattern in user code:
if string(a) == string(b) { ... }
if string(a) == "literal"  { ... }
```

### Gotcha — keep conversions on *both* sides of the operator

```go
// verbose but zero allocations
switch {
case string(x) == string(y): // elided
case string(x) == string(z): // elided
}

// clean but 3 allocations
switch string(x) {
case string(y): ...   // the explicit switch-expr allocates string(x)
case string(z): ...   // string(y), string(z) as case exprs allocate
}
```

Write the verbose form when the slices are large.

### `bytes.Compare` for three-way comparisons only

`bytes.Compare(a, b)` is faster than hand-rolled three-way. For two-way equality, `string(a) == string(b)` is faster than `bytes.Compare(a, b) == 0`.

## 9.1.3 — `m[string(b)]` (lookup) does NOT allocate

```go
var m map[string]int
var key []byte

_ = m[string(key)]   // does NOT allocate

m[string(key)] = 42  // DOES allocate (it's a modification)
m[string(key)]++     // DOES allocate (expands to read + modify)
```

### Workaround for increment-heavy maps: pointer values

If you need to mutate map values under a `[]byte` key, use a pointer value type so the map expression is a pure lookup:

```go
m := map[string]*int{"key": new(int)}

var key []byte = ...
*m[string(key)]++    // lookup is elision-eligible; mutation goes through the pointer
```

Caveat: if map entries are **deleted** frequently, the pointer value type's allocation cost on insert will outweigh the lookup savings. The trick fits "read-heavy, mutate-heavy, seldom-insert/delete".

### Composite-literal wrapping preserves the elision

As long as the `string(key)` appears inside a struct/array literal used as the map key, the elision still applies:

```go
type K struct { a int; b bool; k [2]string }
var m map[K]int

_ = m[K{k: [2]string{1: string(key)}}]   // does NOT allocate
```

## 9.1.4 — `string(b)` inside a string concat with a non-empty string constant may not allocate

Only in concat expressions; only when at least one operand is a non-empty **constant** string; only when the result is > 32 bytes (see §9.1.5).

```go
// faster: 1 allocation total
return (" " + string(s) + string(s))[1:]

// slower: 3 allocations
return string(s) + string(s)
```

The trick wastes 1 byte (the leading space that gets sliced off). Avoid it when you know a byte value of one of the operands — pivot on that instead:

```go
return "$" + string(s[1:]) + string(s)   // when s[0] is always '$'
```

**Treat this trick as unintended and liable to disappear in future Go versions.** Use `strings.Builder` or a `[]byte` buffer in code you plan to keep long-term.

## 9.1.5 — Results > 32 bytes always heap-allocate

For the result of a string-producing operation (conversion, concat), if the length > 32 the bytes **always** go to the heap. At ≤ 32 bytes they can stay on the stack if the result doesn't escape.

For constant strings, the stack threshold relaxes to 64 KiB.

**Consequence — splitting a concat can save allocations:**

```go
// 3 heap allocations, 420 ns/op
str = string(s37) + string(s37)              // both conversions hit >32

// 1 heap allocation, 360 ns/op
str = string(s37[:32]) + string(s37[32:]) +
      string(s37[:32]) + string(s37[32:])    // each piece ≤ 32 → stack
```

## 9.2 — Concatenating strings

Two main tools:

| Tool | Best for | Notes |
|---|---|---|
| `+` operator | concat that fits in a single expression | Result ≤ 32 bytes can stack-allocate. Simpler. |
| `strings.Builder` | concat where the count/size is dynamic | Always heap. `Grow(n)` once if you know n. |

If you can express the concat in a single `a + b + c` statement, **prefer `+`**. It's as fast as or faster than `Builder` for small counts. `Builder`'s own allocation cost dominates for small strings.

```go
// fast
return a + b + c

// same speed, more verbose, but general
var b strings.Builder
b.Grow(len(a)+len(b2)+len(c))  // skip if you don't know
b.WriteString(a); b.WriteString(b2); b.WriteString(c)
return b.String()
```

### `strings.Builder` over-allocation

When you don't call `Grow(n)` upfront, the internal `[]byte` grows geometrically. The final string keeps that backing array — so the cap can exceed the string length. Memory waste until GC.

Always `Grow(n)` if you can estimate `n`.

### Byte-slice buffer alternative

A third way: build a `[]byte` manually, then `string(bs)` once.

```go
func concat(ss ...string) string {
    n := 0
    for _, s := range ss { n += len(s) }
    var bs []byte
    if n > 64 {
        bs = make([]byte, 0, n)     // heap
    } else {
        bs = make([]byte, 0, 64)    // constant-cap buffer can stay on stack
    }
    for _, s := range ss { bs = append(bs, s...) }
    return string(bs)
}
```

The fixed-cap branch lets the buffer stay on the stack. Faster than `Builder` when the result fits, slower when it doesn't.

When you see a hot-path `+`/`Builder` with results always ≤ some small number, this pattern often wins.

## 9.3 — Merging a string and a byte slice into a new byte slice

```go
// way 1 — one-line
newBS := append([]byte(str), bs...)

// way 2 — make+copy
newBS := make([]byte, len(str)+len(bs))
copy(newBS, str)
copy(newBS[len(str):], bs)
```

- `str` much larger than `bs` → way 2 wins (no throwaway `[]byte(str)`).
- `bs` much larger than `str` → way 1 wins (the `append` reuses the allocation for the conversion).

Neither way is optimal; the compiler doesn't yet have a perfect codegen for this. When latency is critical, write a tiny benchmark to pick between the two for your specific sizes.

## 9.4 — `strings.Compare` is slow on purpose; use `==` / `<`

As of 1.19, `strings.Compare` is a toy wrapper on `==/<`, not an optimized comparator like `bytes.Compare`. Don't use it in hot code.

For three-way, hand-rolled order of branches matters:

```go
// GOOD — check equality first if lengths are usually unequal; x==y is fast when lengths differ.
func f1(x, y string) {
    switch {
    case x == y: ... // eq
    case x < y : ... // lt
    default    : ... // gt
    }
}

// BAD — x < y and x > y both force full prefix compare.
func f3(x, y string) {
    switch {
    case x < y: ...
    case x > y: ...
    default   : ... // eq
    }
}
```

## 9.5 — Allocation-saving patterns

### Reorder concats to reuse substrings

```go
// 1 allocation: abc is built once, ab is a subslice.
abc := a + b + c
ab  := abc[:len(abc)-len(c)]

// 2 allocations: ab and abc are two separate result strings.
ab  := a + b
abc := ab + c
```

### Compound map keys — arrays beat concatenated strings

```go
var ma = map[[2]string]struct{}{}   // no allocations per insert
var ms = map[string]struct{}{}      // allocates the joined key

ma[[2]string{a, b}] = struct{}{}
ms[a + "/" + b]     = struct{}{}
```

Measured:

```
Benchmark_array_key    147 ns/op     0 B/op     0 allocs/op
Benchmark_string_key   508 ns/op    40 B/op     3 allocs/op
```

Use struct keys when you have mixed types, array keys for same-type.

### Case-insensitive comparison

`strings.EqualFold(a, b)` doesn't allocate.  
`strings.ToLower(a) == strings.ToLower(b)` allocates two strings per call.

~6× difference. Always use `EqualFold` on hot paths.

### `WriteString` on writers — avoid `[]byte(s)` on every call

```go
// allocates a []byte per call
w.Write([]byte(s))
```

If the writer supports it, use `io.WriteString(w, s)` — this checks for a `stringWriter` interface and avoids the conversion when possible. `bufio.Writer` already has `WriteString`. When writing your own writer, implement `WriteString([]byte) (int, error)` as well so your callers skip the conversion.

## 9.1 vs rest of the language — rules of thumb

| Pattern | Allocates? |
|---|---|
| `for _, b := range []byte(s)` | no |
| `string(b) == string(b2)` | no |
| `string(b) == "literal"` | no |
| `m[string(b)]` (read) | no |
| `m[string(b)] = v` (write) | **yes** |
| `m[string(b)]++` (compound) | **yes** (unless value is pointer) |
| `T{..., string(b), ...}` key into `m` (read) | no |
| `string(b)` in `+ "lit" + string(b2)` with result > 32 | no (by elision rule) |
| Plain `string(b)` anywhere else | **yes** (> 32 bytes → heap, ≤ 32 → stack) |
| `a + b + c` where `len(...) > 32` | 1 heap alloc |
| `a + b + c` where `len(...) ≤ 32`, result doesn't escape | 0 heap allocs (stack) |
| `strings.Builder` with `Grow(n)` | 1 heap alloc |
| `strings.EqualFold(x, y)` | no |
| `strings.ToLower(x)` | yes |
