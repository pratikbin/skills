# Structs

Three concrete rules. (§7.2 is size-related and lives in `value-sizes.md`.)

## 7.1 — Don't read/write a struct field through a pointer inside a loop

This is the same issue as §6.2 (pointer dereference in a loop). The compiler re-loads and re-stores the field every iteration because it can't prove nothing aliases it.

Slow:

```go
type T struct{ x int }

func f(t *T) {
    t.x = 0
    for i := 0; i < N; i++ {
        t.x += i   // load-add-store to memory every iter
    }
}
```

Fast — accumulate locally, write once:

```go
func g(t *T) {
    x := 0
    for i := 0; i < N; i++ {
        x += i
    }
    t.x = x
}
```

Measured:

```
Benchmark_f   2402 ns/op
Benchmark_g    461 ns/op
```

~5× faster from the same semantic result.

**Aliasing caveat** (same as §6.2): if the loop body has another write through a pointer that could alias `t.x`, the local-accumulator version silently disagrees with the in-place version. If in doubt, return the value instead.

## 7.2 — Small structs are passed in registers; large ones aren't

(Detail in `value-sizes.md`.) Rule of thumb at gc 1.19, amd64:
- Struct with **≤ 4 word-size fields**: pass/return by value freely.
- Struct with **≥ 10 word-size fields**: prefer pointer receivers/params in hot code — per-call copy cost doubles around that cliff.
- Register ABI for all-float32 structs cuts off around 4 fields — a `T5 struct{a,b,c,d,e float32}` is ~7× slower to pass than `T4 struct{a,b,c,d float32}` in the book's benchmark.

When deciding pointer vs value for a small struct, default to **value** — copies are cheap, method inlining is easier, and you avoid escape risk from callers that take addresses. Switch to pointer only when profiling says the copy hurts or when you need mutability.

## 7.3 — Shrink structs by reordering fields widest → narrowest

The compiler inserts padding to meet alignment. Field order can change `sizeof(T)` substantially.

```go
type Bad struct { // 24 bytes on 64-bit
    a int8
    b int64     // 7 bytes padding before
    c int16     // 6 bytes tail padding
}

type Good struct { // 16 bytes
    b int64
    c int16
    a int8
    // 5 bytes tail padding
}
```

Verify with `unsafe.Sizeof(T{})` or run `fieldalignment` (part of `golang.org/x/tools/go/analysis/passes/fieldalignment`). A common place this matters: structs held in a large slice or map — a single byte saved on the type saves bytes × N across the container.

### When *not* to reorder

- **Readability / locality of meaning.** If fields form a natural group (e.g., `{x, y, z float32}` for a 3D point), keep them together. The group is already same-width so padding isn't hurt.
- **Atomic alignment requirements.** Some `sync/atomic` operations on 64-bit fields require 8-byte alignment; on 32-bit architectures you may need to place those fields first.
- **Public structs exposed as part of a wire format.** Obvious.

### Review heuristic

When the struct is:
- allocated in numbers (slice/map of struct, channel of struct),
- or hot (read/written many times per second),

reorder fields widest-first and verify with `unsafe.Sizeof`. Otherwise leave it — readability is worth more than 8 bytes.

## Accessing slice-of-struct fields in a loop

Combine §7.1 and the range-variable-copy trap (`value-sizes.md` §2.7):

- `for _, v := range slice` → `v` is a copy of each struct. Big struct = big copy per iter.
- `for i := range slice` + `slice[i].field` → no copy, but the compiler may re-load the slice header.
- `for i := range slice { p := &slice[i]; … }` → once-per-iter pointer load, then cheap field access.

All three may be equivalent when the element type is small (≤ 4 word fields). Only reach for the last form when the struct is bigger and the loop is hot.
