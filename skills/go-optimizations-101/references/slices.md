# Arrays and slices

## 8.1 — Don't compare large arrays against a literal

`*t == T{}` allocates / emits extra instructions for a large `T`. Use a package-level zero-value instead.

```go
type T [1000]byte
var zero = T{}

// slow — ~52 ns/op
func CompareWithLiteral(t *T) bool   { return *t == T{} }

// fast — ~31 ns/op
func CompareWithGlobalVar(t *T) bool { return *t == zero }
```

Only matters for arrays. For small structs (≤ a few words), there's no measurable difference.

## 8.2 — Slice-to-array-pointer conversion (1.17+) is faster than `copy` for small buffers

If the total size of the copy is ≤ 64 bytes, a cast-and-assign is faster than `copy`. The compiler emits a direct MOV sequence.

```go
func copy2(d, s []byte) {
    *(*[N]byte)(d) = *(*[N]byte)(s)  // requires len(d) >= N and len(s) >= N
}
```

For size 32 (one example in the book): `copy` 4.6 ns/op → cast 1.4 ns/op.

**Don't use this for large buffers** — it regresses, and at very large sizes it's much worse. Book suggests staying below 64 bytes.

Safety: you must guarantee `len` on both slices is ≥ `N` before the conversion. Go will panic otherwise. Use it only when you know the sizes (e.g., parsing a fixed-size header).

## 8.3 — `make` + `copy` has a specially optimized zero-elision

Since Go 1.15, the compiler elides the zero-fill when this exact pattern holds:

```go
y := make([]T, n)
copy(y, x)     // elides zeroing of the elements copy will overwrite
```

Restrictions (all must hold):
- `y` must be a plain identifier (not an indexed/field access).
- `make` takes exactly 2 args (no explicit capacity).
- The `copy(y, x)` call must be the **full statement**, not wrapped (`_ = copy(...)` defeats it, so does `f(copy(...))`).
- These defeat the optimization too:
  - `make([]T, n, n)` (3-arg make)
  - `y := make([]T, len(a[0]))` (indexed arg)
  - `y := make([]T, len(ss.x))` (struct-field arg)

The optimization only covers the range the `copy` writes. If you copy into a prefix and then append more, the rest still gets zeroed:

```go
s := make([]T, len(x)+len(y))
copy(s, x)                // elides zero-fill of s[:len(x)]
copy(s[len(x):], y)       // s[len(x):] was already zeroed by make — wasted work
```

### Append capacity growth algorithm

gc 1.17:

```
required = old.len + values.len
if required > old.cap * 2:
    newcap = required
else if old.cap < 1024:
    newcap = old.cap * 2
else:
    newcap = old.cap
    while newcap < required:
        newcap += newcap / 4
```

gc 1.18+ (smoother, uses 256 threshold):

```
    if old.cap < 256:
        newcap = old.cap * 2
    else:
        newcap = old.cap
        while newcap < required:
            newcap += (newcap + 3*256) / 4
```

The result is rounded up to a size-class boundary. Growth is non-monotonic across versions — don't assume a particular cap.

## 8.4 — Clip the first arg of `append` when you know it'll allocate

If `append(x, y...)` will allocate **and** you won't append again to the result, clip `x` first so the new backing array doesn't over-allocate.

```go
x := make([]byte, 100, 500)
y := make([]byte, 500)
a := append(x, y...)                     // cap(a) = 1024 (1.17) or 896 (1.18)
b := append(x[:len(x):len(x)], y...)     // cap(b) = 640 — tighter
```

If `cap(x) - len(x)` is already enough to hold `y`, don't clip — clipping forces an allocation you didn't need.

`slices.Clip(x)` (stdlib 1.21+) does the same thing readably.

## 8.5 — Grow a slice to capacity `c`

Two idiomatic shapes, both optimized:

```go
// way 1 — make+copy: most predictable, usually a hair faster
func grow(x []T, c int) []T {
    r := make([]T, c)
    copy(r, x)
    return r[:len(x)]
}

// way 2 — append with throwaway slice
func growOneline(x []T, c int) []T {
    return append(x, make([]T, c-len(x))...)[:len(x)]
}
```

Gotcha for way 2: if you wrap the element type (`type S []T`; `make(S, ...)`), the optimization breaks on 1.19 and it allocates. Fixed in 1.20. Default to way 1.

## 8.6 — Grow once, not many times

Every growth is a separate allocation + copy. Estimate max length up front and allocate that.

For short-lived slices, a generous over-estimate is fine — the memory comes back quickly, and you skip several growths.

## 8.7 — Cloning a slice

Fastest form (1.15+):

```go
clone := make([]T, len(s))
copy(clone, s)
```

The `append([]T(nil), s...)` idiom also works but may over-allocate (the example in the book: a 32769-element slice cloned with `append` leaves 8191 trailing slots in the result). In 1.21+, `slices.Clone(s)` does the right thing.

## 8.8 — Merging two slices

If element order matters:

```go
// make+copy
merged := make([]T, len(x)+len(y))
copy(merged, x)
copy(merged[len(x):], y)

// append — cleaner but sometimes over-allocates and zeros extra
merged := append(x[:len(x):len(x)], y...)
```

Pick `append` when `len(y)` is much larger than `len(x)`, otherwise the `make+copy` form.

### If element order doesn't matter — pass the shorter slice second

`append(long, short...)` allocates less than `append(short, long...)`:

```go
x := make([]int, 98)
y := make([]int, 666)
cap(append(x, y...))  // 768 or 1024
cap(append(y, x...))  // 1360 (1.17) or 1024 (1.18)
```

If `x`'s free capacity can hold `y` and aliasing with `x` is acceptable, `append(x, y...)` allocates zero. Fastest.

## 8.9 — Merging N slices

```go
// Clean, order-preserving. Acceptable for almost all code.
n := 0
for _, s := range ss { n += len(s) }
r := make([]byte, 0, n)
for _, s := range ss { r = append(r, s...) }
```

If order can be permuted, there's a "start from the longest" variant that triggers the `make+copy` optimization better — but it's verbose. Only use it when benchmarks demand it.

## 8.10 — Inserting a slice at position `k`

Fastest general shape (triggers the zero-fill elision on 1.18+):

```go
func insert(s []byte, k int, vs []byte) []byte {
    a := s[:k]
    out := make([]byte, len(s)+len(vs))
    copy(out, a)
    copy(out[len(a):], vs)
    copy(out[len(a)+len(vs):], s[k:])
    return out
}
```

Avoid the one-liner `append(s[:k:k], append(vs, s[k:]...)...)` — it copies `s[k:]` twice and usually does two allocations.

If `cap(s)` already has room and in-place is acceptable:

```go
s = s[:len(s)+len(vs)]
copy(s[k+len(vs):], s[k:])  // shift right
copy(s[k:], vs)
```

If insertions happen frequently, slices are the wrong data structure.

## 8.11 — Don't use the second range variable over big elements

Each iteration copies the element into `v`. For a slice of big structs this doubles (or more) the loop cost.

Slow:

```go
for _, v := range s { sum += v.field }
```

Fast:

```go
for i := range s    { sum += s[i].field }
// or
for i := range s {
    p := &s[i]
    sum += p.field
}
```

Even for small element types, the second-variable form is slightly slower. For arrays the cost is double (the array itself is copied in addition to the per-element copy).

## 8.12 — Zeroing elements — use the idiomatic range

Since 1.5, this exact shape is compiled to `memclr`:

```go
var zero T
for i := range s { s[i] = zero }
// 1.19+ also works on *[N]T
```

`for i := 0; i < len(s); i++ { s[i] = zero }` is *not* the optimized form, and is slower unless `len(s) < ~6`.

For an array, the cleanest way is still `*arrPtr = ArrType{}`.

(Go 1.21 added the `clear()` builtin which does the right thing for both slices and maps.)

## 8.13 — Prefer `s[i:j:j]` over `s[i:j]` when possible

The compiler emits extra CPU instructions for `s[a:b]` when it can't prove the result's cap is non-zero in a way that prevents the element pointer from falling on a memory-block boundary. Writing `s[a:b:b]` removes that uncertainty, so the compiler emits fewer instructions.

```go
// 32.9 ns/op
for i := 0; i < len(bs)-3; i += 4 {
    s2 := bs[i : i+4]
    r[j] = s2[0] ^ s2[1] ^ s2[2] ^ s2[3]
    j++
}

// 25.7 ns/op (~22% faster)
for i := 0; i < len(bs)-3; i += 4 {
    s2 := bs[i : i+4 : i+4]
    r[j] = s2[0] ^ s2[1] ^ s2[2] ^ s2[3]
    j++
}
```

**Warning:** the 3-index form caps the slice. If you `append` to `s2` afterwards, the behaviour differs (a clipped slice will allocate on the next growth; a non-clipped one may not). Use the 3-index form only when you're done growing.

## 8.14 — Replace multi-case switches with index tables

When a hot dispatch tests membership in a small set of constants, an index table is faster.

```go
// 1–5 comparisons per call
func foo(n int) {
    switch n % 10 {
    case 1, 2, 6, 7, 9:
        // branch A
    default:
        // branch B
    }
}

var table = [10]bool{1: true, 2: true, 6: true, 7: true, 9: true}

// 1 indexed load per call
func bar(n int) {
    if table[n%10] {
        // branch A
    } else {
        // branch B
    }
}
```

Works for any small, dense integer key space. Same trick for small enum-like dispatches elsewhere in the codebase — see `maps.md` §11.7 for the map equivalent.
