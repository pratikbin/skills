# Value parts, sizes, alignment, copy costs

The rest of the references assume the terminology and numbers on this page. Read this first.

## Direct part vs indirect part

Go values have one **direct part** (always copied on assignment) and sometimes one or more **indirect parts** (referenced, not copied). This distinction is what makes some copies cheap and others expensive.

| Has only a direct part (entire value is copied) | May have indirect parts (only the header is copied) |
|---|---|
| `bool`, all numeric (`int`, `uint8`, …, `complex128`) | slice |
| pointer, `unsafe.Pointer` | map |
| struct (fields live inline) | channel (buffer lives elsewhere) |
| array (elements live inline) | function |
| | interface (dynamic value lives elsewhere) |
| | string (bytes live elsewhere) |

Consequence: **a slice, map, channel, function value, interface, or string is always cheap to pass**. A big struct or big array is not.

## Type sizes (official gc compiler, 64-bit = 8-byte word)

| Type | Size |
|---|---|
| `bool`, `int8`, `uint8`, `byte` | 1 byte |
| `int16`, `uint16` | 2 |
| `int32`, `uint32`, `float32`, `rune` | 4 |
| `int64`, `uint64`, `float64`, `complex64` | 8 |
| `complex128` | 16 |
| `int`, `uint`, `uintptr`, pointer, `map`, `chan`, `func` | 1 word (8 bytes on 64-bit) |
| `string`, interface | 2 words (16 bytes) |
| slice | 3 words (24 bytes) |
| array | `element_size * length` (0 if element size is 0) |
| struct | sum of field sizes + padding (0 if all fields are zero-size) |

`map`, `chan`, `func` are represented internally as pointers — that's why they're 1 word and why assigning them is always cheap.

## Alignment guarantees

| Type | Alignment |
|---|---|
| `bool`, `int8`, `uint8` | 1 |
| `int16`, `uint16` | 2 |
| `int32`, `uint32`, `float32`, `complex64` | 4 |
| arrays | same as element type |
| structs | max alignment of any field |
| everything else | 1 word (8 on 64-bit) |

The compiler guarantees: `size_of(T)` is always a multiple of `align_of(T)`. That is where struct tail-padding comes from.

## Struct padding — field order matters

Fields are laid out in source order. The compiler inserts padding to meet alignment. Reordering fields from **largest** to **smallest** usually gives the smallest size.

```go
type T1 struct { // size 24 on 64-bit
    a int8      // 7 bytes padding after
    b int64
    c int16     // 6 bytes padding after (tail)
}

type T2 struct { // size 16 on 64-bit
    a int8
    c int16     // 1 byte padding before c, then 4 bytes after to 8-align b
    b int64
}
```

Verify with `unsafe.Sizeof(T{})`. Lint with `fieldalignment` (`golang.org/x/tools/go/analysis/passes/fieldalignment`).

Rule: order fields widest → narrowest unless readability (grouping related fields) matters more. Group related → widest first within the group.

## Value copy costs

Cost of copying a value is ~proportional to its size, plus CPU-cache and compiler effects. The compiler has a **small-value fast path** that matters.

### Small-size types (copy is very cheap)

There is no formal definition, but a useful rule of thumb for the gc compiler at 1.19:

- All types except "large" structs and arrays are small-size.
- Structs with **≤ 4 word-sized fields** and arrays with **≤ 4 word-sized elements** are small-size.
- A second threshold kicks in around 10: copying an array of 9 vs 10 `uint64`s, or a struct of 9 vs 10 word-sized fields, roughly doubles cost (~2× per iteration).

Measured (gc 1.19, amd64, from the book):

```
Benchmark_CopyArray_9_elements    3974 ns/op
Benchmark_CopyArray_10_elements   8896 ns/op
Benchmark_CopyStruct_9_fields     2970 ns/op
Benchmark_CopyStruct_10_fields    8471 ns/op
```

And register-passing for `float32` structs cuts off around 4 fields:

```go
type T4 struct{ a, b, c, d float32 }    // ~2.6 ns/op for Add4
type T5 struct{ a, b, c, d, e float32 } // ~19 ns/op for Add5
```

**Practical rules:**
- Struct ≤ 4 word-sized fields → pass by value; register-ABI makes this cheap.
- Struct > ~9 word-sized fields → pass by pointer if you don't need copy semantics, or accept the cost if you do.
- Array > ~9 elements → pass by pointer (`func f(a *[N]T)`) or convert to a slice.
- On register-rich architectures the 4-vs-5-`float32` cliff can differ. Benchmark if it matters.

### Where copies happen

Not only assignments — all of these are value copies:

- Converting a non-interface value to an interface (**boxing**). `var x any = int64(5)` may allocate.
- Passing arguments / returning results in a function call.
- Sending to or receiving from a channel.
- Inserting into a map (`m[k] = v` copies `v`).
- `append` that grows the backing array (every element of `s` is copied).
- `for _, v := range c` — every element is copied into `v`.

### The `for _, v := range ...` trap

Using the **second** iteration variable copies the element into `v`. For large-element containers this is a visible cost.

Fast:

```go
for i := range s {
    sum += s[i].x
}
// or
for i := range s {
    p := &s[i]
    sum += p.x
    sum += p.y
}
```

Slow (copies each element into `v`):

```go
for _, v := range s { // v = copy
    sum += v.x
    sum += v.y
}
```

Benchmarked on `[]struct{a,b,c,d,e int}`:

```
Benchmark_UseSecondIterationVar    2208 ns/op
Benchmark_OneIterationVar_Index    1212 ns/op
Benchmark_OneIterationVar_Ptr      1182 ns/op
```

**Reduce field count to ≤ 4 and the gap disappears** — the compiler uses the small-size fast path and the copy is free.

### Range over array vs array-pointer vs slice

Passing a big array by value copies it on the call **and** on the range. Passing a pointer to the array, or passing a slice, avoids the copies.

```go
func sumArray(a [N]int) (r int)   { for _, v := range a { r += v }; return }   // 2 copies
func sumArrayPtr1(a *[N]int) (r int){ for _, v := range *a { r += v }; return } // 1 copy (the range deref)
func sumArrayPtr2(a *[N]int) (r int){ for _, v := range a { r += v }; return }  // 0 copies — ranging a pointer
func sumSlice(a []int) (r int)    { for _, v := range a { r += v }; return }   // 0 copies — slice header only
```

Ranging directly over `*[N]T` iterates without copying the array (Go 1.17+ supports this ergonomically via slice-to-array-pointer too, see `references/slices.md`).

## Applying this in review

When you see a hot-path function that takes a struct or array by value, ask:
1. Is the type small (≤ 4 words)? → probably fine.
2. Is it larger? Is the caller in a loop? → recommend pointer receiver / parameter.
3. Is it a `for _, v := range s` over a non-trivial element type? → rewrite to index form.
4. Is the struct size bloated by padding? → reorder fields widest → narrowest and recheck `unsafe.Sizeof`.
