# Memory allocations

## Mental model

- Every value part lives in a **memory block**. A block can carry more than one part; its size must be at least the largest part it holds.
- Blocks come from either the **stack** of a goroutine or the **heap**.
- Stack blocks are free to allocate and free; they die with the goroutine frame.
- Heap blocks are expensive to allocate and create GC pressure. They're the only ones counted in `-benchmem`'s `allocs/op`.
- Fewer heap allocations = less CPU **and** less GC work. Double win.

## Operations that can allocate

Each of these may cause at least one allocation. The compiler elides some; don't assume it does.

- Variable declarations (if the variable escapes; see `escape-analysis.md`).
- `new(T)` — always allocates a zeroed `T`. Result usually escapes.
- `make(T, …)` for slice/map/channel.
- Slice/map composite literals used in ways that force heap (e.g. `&[]int{…}`).
- Integer → string conversion.
- String concatenation with `+` (when it doesn't fit into a known constant fold).
- `string([]byte)`, `[]byte(string)`, `string([]rune)` — with big exceptions, see `strings.md`.
- Boxing a non-interface value into an interface (e.g. `any(x)`).
- `append` when the destination slice's capacity is too small.
- Inserting into a map whose backing array is full.

## Memory-block size classes (gc 1.19)

The allocator has fixed size classes. Requesting 33 bytes gives you a 48-byte block.

| Payload size | Block size | Waste |
|---|---|---|
| 1–8 | 8 | up to 7 |
| 9–16 | 16 | up to 7 |
| 17–24 | 24 | up to 7 |
| 25–32 | 32 | up to 7 |
| 33–48 | 48 | up to 15 |
| 49–64 | 64 | up to 15 |
| 65–80 | 80 | up to 15 |
| 81–96 | 96 | up to 15 |
| …classes continue up to 32768… |
| > 32768 | multiple of 8192 (page size) | up to a page |

Consequence: `make([]byte, 32769)` allocates **40960** bytes (5 pages).

A `string(s) + string(s)` where `len(s) == 33` allocates **3** blocks totalling **176** bytes (48 + 48 + 80) for 66 bytes of payload — 44 wasted.

Understanding size classes explains:
- why growing a slice from cap 32768 to 32769 jumps allocation cost a lot,
- why struct sizes at `size + 1` past a class boundary can hurt more than you'd expect,
- why it sometimes helps to shrink a struct by one field to cross back under a boundary.

## Rule 1 — Preallocate when you know or can estimate the size

`append` in a loop grows geometrically but still allocates. If you can compute the final length in O(n) or have an upper bound, do it and `make` once.

### Slow (4 allocations, several copies)

```go
func mergeOne(data [][]int) []int {
    var r []int
    for _, s := range data {
        r = append(r, s...) // reallocs: cap grows 0→2→6→12→24
    }
    return r
}
```

### Fast (1 allocation, 0 copies past the final append)

```go
func mergeTwo(data [][]int) []int {
    n := 0
    for _, s := range data {
        if k := n + len(s); k < n {
            panic("length overflow") // keep this — worth the branch
        } else {
            n = k
        }
    }
    r := make([]int, 0, n)
    for _, s := range data {
        r = append(r, s...)
    }
    return r
}
```

Measured (gc 1.19):

```
Benchmark_MergeWithOneLoop    636.6 ns/op   352 B/op   4 allocs/op
Benchmark_MergeWithTwoLoops   268.4 ns/op   144 B/op   1 allocs/op
```

**Caveat:** `make([]T, 0, n)` still zeroes the (0-length) header and `make([]T, n)` zeros all n elements — zeroing is not free. When you overwrite every element right after, the zero is wasted work. The compiler keeps improving at eliding zeros; `benchstat` before deciding.

## Rule 2 — Allocate zero if you can

One allocation beats four. Zero allocations beat one. Sometimes you can reuse a caller-provided slice.

### In-place filter (zero allocations, mutates input)

```go
func filterInPlace(data []int) []int {
    k := 0
    for i, v := range data {
        if keep(v) {
            data[i] = data[k]
            data[k] = v
            k++
        }
    }
    return data[:k]
}
```

Measured:

```
Benchmark_FilterOneAllocation    7263 ns/op   8192 B/op   1 allocs/op
Benchmark_FilterNoAllocations     903 ns/op      0 B/op   0 allocs/op
```

8x faster. Cost: input is mutated. Document it.

Common "accept a destination slice" pattern:

```go
// AppendFoo appends the encoding of x to dst and returns the extended slice.
func AppendFoo(dst []byte, x Foo) []byte { ... }
```

This is the `strconv.AppendInt` style. It lets the caller reuse a buffer.

## Rule 3 — Combine many small allocations into one large one

Allocating 100 values in one block is ~4× faster than 100 individual allocations and usually uses slightly less memory (fewer size-class wastes).

### Slow (101 allocations)

```go
func createBooksMany(n int) []*Book {
    books := make([]*Book, n)
    for i := range books {
        books[i] = new(Book) // one alloc per iteration
    }
    return books
}
```

### Fast (2 allocations)

```go
func createBooksOneBlock(n int) []*Book {
    books  := make([]Book,  n) // one big block for all Book values
    pbooks := make([]*Book, n) // one block for the pointers
    for i := range pbooks {
        pbooks[i] = &books[i]
    }
    return pbooks
}
```

Measured (N=100, Book size 40 B):

```
Benchmark_CreateOnOneLargeBlock-4    4372 ns/op   4992 B/op     2 allocs/op
Benchmark_CreateOnManySmallBlocks-4 18017 ns/op   5696 B/op   101 allocs/op
```

**Gotcha:** at certain `N` (820–852 in the book example), the large block crosses the 32768-byte size-class boundary and needs 5 whole pages, at which point the many-small version briefly uses less memory. Mostly not worth worrying about, but know this if you're deciding at the margin.

**When it pays the most:** short, similar lifetimes. If one of the small values outlives the rest, the whole slab stays alive — this is the arena trade-off. `memory-fragmentation` → see `garbage-collection.md` §5.5.

## Rule 4 — Use a cache/free-list pool when you churn

If you `new()` and discard values of the same type many times per second, pool them.

### Hand-rolled pool (good when lifetime is bounded)

```go
var npcPool = struct {
    sync.Mutex
    *list.List
}{List: list.New()}

func newNPC() *NPC {
    npcPool.Lock()
    defer npcPool.Unlock()
    if npcPool.Len() == 0 {
        return &NPC{}
    }
    return npcPool.Remove(npcPool.Front()).(*NPC)
}

func releaseNPC(npc *NPC) {
    npcPool.Lock()
    defer npcPool.Unlock()
    *npc = NPC{} // zero before returning — prevents stale data leaks
    npcPool.PushBack(npc)
}
```

If the pool is accessed from only one goroutine, drop the mutex.

### `sync.Pool`

Standard library. Differences:
- Pooled objects may be reclaimed by GC after two idle cycles. Capacity is dynamic.
- A single `sync.Pool` can hold different-sized objects, but **don't do that** — put same-type-same-size objects only, or you'll get unpredictable memory use.
- There's per-P sharding so it scales under contention.

Trade-offs:
- Good for large buffers reused in request-scoped code (e.g. `bytes.Buffer`, scratch `[]byte`). The bigger the object, the more you save per hit.
- Bad for very small objects — the pool overhead can exceed the allocation it replaces.
- Your pooled object **must be safely resettable**. Common bug: forgetting to `buf.Reset()` leaks caller data to the next user.

Before committing to a pool, benchmark. A pool can regress latency if the hit rate is low (cold pool warms up during each run).

## Rule 5 — Know when allocation doesn't happen

The compiler elides allocations in specific shapes. Don't "optimize" code that doesn't allocate in the first place.

- String-to-`[]byte` conversion **as the range expression** of a `for _, b := range []byte(s)` doesn't allocate. See `strings.md` §9.1.1.
- `[]byte`-to-string as a **map key lookup** (`m[string(b)]`) doesn't allocate. §9.1.3.
- `[]byte`-to-string as one operand of a comparison (`string(b) == "foo"`) doesn't allocate. §9.1.2.
- `[]byte`-to-string inside a string concat where at least one operand is a non-empty constant may not allocate. §9.1.4.
- Small values pass in registers with no heap involvement even though they "look" boxed. See `interfaces.md`.

Verify with `go build -gcflags='-m=2'`.

## Debugging checklist for "too many allocations"

1. `go test -bench=X -benchmem` — get concrete `allocs/op`.
2. `scripts/alloc_profile.sh` — see **where**.
3. `scripts/escape_analysis.sh` — see **why** the site moves to the heap.
4. Apply rules 1–4 above in order of cost: preallocate first, zero-alloc if feasible, then combine blocks, then pool.
5. Re-measure with `benchstat`. If improvement is in noise, revert.
