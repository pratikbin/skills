# Interfaces

An interface value is a (type-descriptor, value-pointer) pair. Assigning a non-interface value into an interface normally copies the value onto the heap and stores the pointer — that's **boxing**, and it's usually one allocation proportional to the value's size. The compiler has a list of special cases that eliminate the allocation; the rest of this reference is that list.

## 14.1 — Boxing costs by type

### The expensive default

```
Benchmark_BoxInt16     18.4 ns/op    2 B/op   1 alloc
Benchmark_BoxInt32     43.5 ns/op    4 B/op   1 alloc
Benchmark_BoxInt64     55.9 ns/op    8 B/op   1 alloc
Benchmark_BoxFloat64   62.6 ns/op    8 B/op   1 alloc
Benchmark_BoxString   104.1 ns/op   16 B/op   1 alloc
Benchmark_BoxSlice    114.6 ns/op   24 B/op   1 alloc
Benchmark_BoxArray    591.9 ns/op  896 B/op   1 alloc
```

### Free boxings (no allocation, ~1 ns)

These shapes allocate **zero** heap bytes:

- **Zero-size values**: `struct{}{}`, `[0]T{}`.
- **`bool` values**.
- **`int8` / `uint8` values** (covered by the zero-alloc 8-bit boxing optimization).
- **Pointers** (`*T`).
- **Maps, channels, functions** — they are internally pointer-sized, so boxing them is boxing a pointer.
- **Constant values of any type** — the value is synthesized at compile time and lives in the binary.

### Cheap-ish boxings (~3 ns, no allocation)

Another tier of zero-alloc cases, slightly slower than the pointer cases because the compiler synthesizes a per-value entry:

- **Non-constant small integer values in [0, 255]** of any integer type (other than 8-bit, which is in the previous tier).
- **Non-constant zero values** of `float32`, `float64`, `string`, and `slice` types.
- A **struct with one field** or an **array with one element** where that field/element is one of the cheap kinds above.

### Expensive boxings (~20–100 ns + 1 alloc)

- Non-zero `float32`/`float64`.
- Non-constant non-small integers (e.g., `int64(9999999)`).
- Non-blank non-constant `string`.
- Non-nil `slice`.
- Any struct/array larger than the single-cheap-field shortcut.

## Practical levers

### Lever 1 — Methods on `*T` make the receiver box as a pointer

If you intend to satisfy an interface with a type, `*T` as receiver is almost always faster for boxing than `T`. Boxing `*T` is pointer-sized (1.2 ns, 0 allocs). Boxing `T` copies.

```go
type Reader interface { Read() int }

type S struct{ v int }

func (s S)  Read() int { return s.v }  // boxing s.Read() into Reader allocates if sizeof(S) > 0
func (s *S) Read() int { return s.v }  // boxing (&s).Read() does not allocate
```

If `T` is very small (≤ 1 word, e.g. `int32`), the value-receiver form can still be free or cheap. If it's anything else, use pointer receiver for interface-satisfaction.

### Lever 2 — Lookup table from values to pointers

If you have a small, enumerable non-pointer type that gets boxed on a hot path, intern it in a global array and box the `*T`.

```go
var values [65536]uint16
func init() { for i := range values { values[i] = uint16(i) } }

// 22.7 ns/op, 1 alloc
r = uint16(i)

// 1.14 ns/op, 0 allocs
r = &values[uint16(i)]
```

~20× faster. Unbox via `*y.(*uint16)`. Works for any type with ≤ 65536 distinct values you might care about.

### Lever 3 — Constants box free

```go
const N int64 = 12345
r = N           // 1.1 ns/op, 0 allocs

var n int64 = 12345
r = n           // 56 ns/op, 1 alloc
```

When possible, make the boxed value a constant — e.g., enum-like `iota` values are free to box.

## 14.2 — Interface→interface assignment doesn't re-box

```go
var v = 9999999
var x, y interface{}

// 130 ns/op, 2 allocs — boxes v twice
x = v
y = v

// 68 ns/op, 1 alloc — boxes v once; y = x just copies the header
x = v
y = x
```

When you pass the same logical value to several interface parameters (e.g., `fmt.Fprint(w, x, x, x)`), box it into a local `var i any = x` first, then pass `i` everywhere.

```go
// 3 allocations
fmt.Fprint(io.Discard, x, x, x)

// 1 allocation
var i any = x
fmt.Fprint(io.Discard, i, i, i)
```

`fmt.Fprintln(w, args...)` with the same arg repeated — do this.

## 14.3 — Interface method calls cost a virtual-table lookup and block inlining

Measured for `Add.Do(x, y float64)`:

```
Benchmark_Add_Inline        0.625 ns/op   (direct call, inlined)
Benchmark_Add_NotInlined    2.340 ns/op   (direct call, no inline)
Benchmark_Add_Interface     4.935 ns/op   (interface call)
```

Two costs to separate:
- ~2.5 ns: virtual-table lookup.
- ~1.7 ns (here): loss from not inlining.

Neither is huge in isolation; both add up in tight loops.

### The compiler devirtualizes when it can

If the compiler sees the concrete type behind the interface at the call site (type assertion, construction in the same scope), it can issue a direct call and potentially inline. Not guaranteed.

Guidance: don't avoid interfaces for design reasons. Do notice them in hot paths — and if a hot loop dispatches through an interface per element, consider specializing.

## 14.4 — Don't design interface params/results for small, hot functions

The `image.Color` / `image.Image.At(x, y) Color` API is a famous Go performance pain point. Every pixel access:
- Boxes a small struct into `Color` (allocation).
- Calls a virtual method through the interface (vtable lookup, no inline).

That's why Go 1.17 added `image/draw.RGBA64Image`:

```go
type RGBA64Image interface {
    image.Image
    RGBA64At(x, y int) color.RGBA64     // concrete return
    SetRGBA64(x, y int, c color.RGBA64) // concrete arg
}
```

Per-pixel allocation disappears.

**Design rule:** for methods called per-element in a big loop, prefer concrete parameter and result types over interface types. Use interfaces one level up (the collection, not the element).

Examples you'll recognize:
- Good: `io.Reader.Read([]byte)` — `[]byte` is concrete; the per-call cost lives in the interface dispatch, not the argument.
- Bad: a hypothetical `Pixel.Get(x, y) Color` where `Color` is an interface.

## Summary — boxing cost cheat sheet

| Boxed | Alloc | ns (1.19) |
|---|---|---|
| `struct{}` / zero-size | 0 | 1.1 |
| `bool`, `int8`, `uint8` | 0 | 1.1–1.8 |
| pointer, map, chan, func | 0 | ~1.2 |
| constant of any type | 0 | ~1.2 |
| non-const small int [0, 255] (non-8-bit) | 0 | ~3.4 |
| zero `float32`/`float64`/`string`/nil-slice | 0 | ~3.5 |
| any other `int32`/`int64` | 1 | ~45–55 |
| non-zero `float64` | 1 | ~60 |
| non-blank `string` | 1 | ~100 |
| non-nil `[]T` | 1 | ~115 |
| large struct/array | 1 | ~size-proportional |

## Review checklist

- [ ] Method receiver: `*T` when `T` has >= 1 word of data and the method is in an interface?
- [ ] Hot per-element function with `any`/interface params? Specialize, or add a concrete sibling API.
- [ ] Repeated boxing of the same value? Box once into a local, reuse.
- [ ] Enumerable small-int type boxed in a loop? Lookup table to `*T`.
- [ ] `fmt.Sprintf`/`fmt.Fprint` with same arg multiple times? Pre-box.
- [ ] Type assertion right after passing through an interface — could we skip the interface entirely?
