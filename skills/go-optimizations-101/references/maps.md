# Maps

## Mental model

- Map backing array grows but **never shrinks**, even after `delete`-ing all entries. To reclaim memory, drop the map (`m = nil` or `m = make(map[K]V)`).
- Hash lookup is O(1) amortized, but has a visible per-op constant: hashing the key. Double-hashing when avoidable is wasted CPU.

## 11.1 — Clearing a map

```go
for k := range m { delete(m, k) }    // specially optimized; keeps backing array
```

To release the backing array too:

```go
m = nil
// or
m = make(map[K]V)   // re-allocates, possibly with explicit size hint
```

Pick:
- **Clear (keep backing array)** if you'll refill with roughly the same number of entries soon. Zero alloc cost to refill.
- **Drop + re-make** if you won't need the map for a while, or need it smaller.

Go 1.21+ adds `clear(m)` which is the stdlib equivalent of the delete-loop, same behaviour (keeps backing array).

## 11.2 — `m[k]++` hashes once; `m[k] = m[k] + 1` hashes twice

```go
m[k]++          // 11 ns/op — hashes k once
m[k] += 1       // 11 ns/op
m[k] = m[k] + 1 // 16 ns/op — hashes k twice
```

Use the compound-assignment forms (`++`, `--`, `+=`, `-=`) with map indexing.

## 11.3 — Pointers in maps are expensive during GC

If neither the key type nor the value type contains pointers, GC does not scan map entries. The runtime tracks this per-map.

Applies equally to slices, arrays, channels — "no pointers in the elements" skips scanning entirely.

### Short-string keys → fixed-size byte array

A `string` contains a pointer. A map with `string` keys is always scanned. If you can guarantee a small max length, use `[N]byte` instead:

```go
var mPtr = make(map[string]int,   1<<16)  // scanned every GC cycle
var mArr = make(map[[32]byte]int, 1<<16)  // not scanned
```

Trade-off: inserting into `mArr` means copying into a `[32]byte`, which is fixed-cost. For very small keys and very large maps, scan-skip wins.

Code to copy a `[]byte` into a `[32]byte` key:

```go
var key [32]byte
copy(key[:], input)   // input must be ≤ 32 bytes
mArr[key]++
```

If inputs can be longer, hash them (e.g., xxhash) into a fixed-size array — this trades insert-side hashing for GC-side scanning.

## 11.4 — Pointer values to avoid mutation allocation

Recall `m[string(b)] = v` **allocates** but `_ = m[string(b)]` doesn't (see `strings.md` §9.1.3).

Bad for a hot counter:

```go
var counter = make(map[string]int)
func inc(w []byte) { counter[string(w)]++ }     // 11600 ns/op, 2336 B/op, 62 allocs
```

Better — value is a `*int`, mutation is through the pointer (pure read on the map):

```go
var counter = make(map[string]*int)
func inc(w []byte) {
    p := counter[string(w)]
    if p == nil {
        p = new(int)
        counter[string(w)] = p  // one alloc per unique key only
    }
    *p++
}
// 1543 ns/op, 0 B/op, 0 allocs (after warm)
```

Best (no extra pointers → smaller GC scan):

```go
var wordIndexes  = make(map[string]int)
var wordCounters []int

func inc(w []byte) {
    if i, ok := wordIndexes[string(w)]; ok {
        wordCounters[i]++
    } else {
        wordIndexes[string(w)] = len(wordCounters)
        wordCounters = append(wordCounters, 1)
    }
}
// 1609 ns/op, 0 allocs, plus no extra pointers for GC
```

The B-way and C-way are close on CPU; C-way wins on long-term GC cost because it doesn't scatter `*int` pointers everywhere.

## 11.5 — Lower mutation frequency

Directly linked to §11.4: each `m[string(b)] = v` is an allocation because the lookup is a write. Restructure so writes happen once per key and subsequent updates go through a pointer or an index — see the counter example above.

## 11.6 — Size the map when creating it

`make(map[K]V, n)` pre-sizes the backing array to hold `n` entries without growing. Growths mean rehashes (every existing key hashed again and moved).

If you'll add ~N entries, pass a hint like `n` equal to that N. Over-estimating is cheap; repeatedly growing is not.

## 11.7 — Use an index table, not a `map[bool]X`

When the key domain is small (bool, byte, small enum), a map is overkill and slower than a direct index.

```go
// ~4 ns/op
func ifElse(x bool) func() {
    if x { return f }
    return g
}

// ~47 ns/op — map lookup + hash + cache miss
var m = map[bool]func(){true: f, false: g}
func mapSwitch(x bool) func() { return m[x] }

// ~4 ns/op — same speed as if/else, with map-like clarity
func b2i(b bool) (r int) { if b { r = 1 }; return }
var a = [2]func(){g, f}
func indexTable(x bool) func() { return a[b2i(x)] }
```

Rule of thumb: if your key space has < 256 values and is contiguous, use `[N]T` (or an array of functions). Map overhead per lookup is ~10× index-table overhead.

## Map review checklist

- [ ] `make(map[K]V, hint)` when size is known?
- [ ] Compound assignments (`m[k]++`) over `m[k] = m[k]+1`?
- [ ] Key/value types pointer-free when possible?
- [ ] For counters/frequent mutations: pointer values or index-into-slice pattern?
- [ ] Clearing: decide whether you want to keep or drop the backing array; document?
- [ ] Small finite key set: consider index table (array) instead?
- [ ] Hot-path lookup from `[]byte`: `m[string(b)]` is fine (elision); `m[string(b)] = v` is not.
