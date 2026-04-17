# Garbage collection

## When GC runs

Three independent triggers, any of which can start a cycle:

1. **Heap-percentage trigger** (the main one). After each cycle, Go computes a *target heap size* for the next one. When live heap hits that target, GC starts.
2. **2-minute timer.** If no cycle has run in ~2 minutes, one runs anyway (mainly so finalizers execute and stacks can shrink).
3. **Memory-limit trigger (1.19+).** When total runtime memory use approaches `GOMEMLIMIT`, GC starts.

### Heap-percentage target formula

Go 1.18+:

```
target_heap = live_heap + (live_heap + GC_roots) * GOGC / 100
```

Before 1.18:

```
target_heap = live_heap + live_heap * GOGC / 100
```

Default `GOGC=100`. Minimum target heap is `GOGC * 4 / 100 MiB` (also the target for the very first cycle).

Consequence of the 1.18 formula change: **larger root sets → larger target heap → fewer GC cycles**. A program with big stacks or big globals gets freer GC scheduling out of the box.

## Two levers to reduce GC pressure

1. **Fewer short-lived heap allocations** (production rate).
2. **Fewer pointers** (scan-and-mark work per cycle).

Pointers that Go tracks:
- Package-level variables.
- Any heap value with a pointer field (transitively).
- Stack frames (all stack contents are treated as roots, pointer or not, for simplicity).

Don't reflexively dodge pointers — they're needed. Just don't make extra ones *that are short-lived and part of tight loops*.

## Common sources of short-lived garbage (hot-path hit-list)

- String concatenation producing temporaries that are consumed once.
- `string ↔ []byte` conversions whose result is used once and dropped.
- Boxing a non-interface value into `any`/`interface{}` and passing it somewhere that immediately pulls it back out.
- `fmt.Sprintf` and `fmt.Println` in hot paths (both allocate and both route through `reflect.ValueOf`; see `escape-analysis.md` §4.6.3).

When reviewing, look for these shapes first. They're frequent and easy to fix (preallocated `[]byte`, `strconv.Append*`, avoid `any` params in hot code).

## Memory-block sharing keeps memory alive

The GC frees a **memory block** only when *all* value parts carried on it are dead. If a tiny long-lived value sits on a big block with otherwise-dead data, the whole block stays.

### Slice: one surviving element pins the whole backing array

```go
s := make([]int, 1000)
var p = &s[999]     // p is long-lived; the other 999 elements can't be freed
```

Fix: copy the tiny live value out so the big block can go.

```go
v := s[999]
p := &v             // now s can be fully collected
```

### `strings.Fields`, `strings.Split`, `bytes.Trim`, etc.

These return substrings/subslices of their input. If the input is big and short-lived, and the return is small and long-lived, you pin the big input. Copy the small result:

```go
parts := strings.Fields(bigInput)
first := strings.Clone(parts[0])   // 1.18+: breaks the alias
// or: first := string([]byte(parts[0]))
```

Same fix with `[]byte`: `append([]byte(nil), subslice...)` or `bytes.Clone` (1.20+).

## `gctrace` — read it quickly

`GODEBUG=gctrace=1 ./yourprog` prints one line per cycle:

```
gc N @Ts P%: ..., A->B->C MB, G MB goal, S MB stacks, H MB globals, ...
```

- `A`: heap size at cycle start (should be ~target).
- `B`: heap size after scan/mark (peak).
- `C`: heap size after sweep (= live heap going forward).
- `G`: target heap size.
- `P%`: cumulative GC CPU share since start.
- `S`: scannable stack size; `H`: scannable globals.

Quick-read: `P%` up near ~10+ means GC is eating your CPU. `C` that barely moves while `A`/`B` bounce around means you're thrashing on short-lived garbage.

## Three mitigations when GC is too busy

### 1. Raise `GOGC`

```
GOGC=500 ./yourprog
```

Lets heap grow 5x live before the next cycle. Less-frequent cycles, but each cycle is bigger and peak memory is higher. Good first knob when the program has spare RAM.

Set `GOGC=off` (or negative via `debug.SetGCPercent(-1)`) to disable the heap-percentage trigger entirely. Note this also disables the 2-minute trigger — finalizers may never run. Use `GOGC=math.MaxInt64` to keep the 2-minute trigger but functionally disable the percentage trigger.

### 2. Memory ballast (pre-1.19, still works in 1.19+)

Create a big, never-used slice to prop up `live_heap` so the target heap is high enough for actual work to fit between cycles.

```go
func main() {
    const ballastSize = 150 << 20 // 150 MiB
    ballast := make([]byte, ballastSize)
    // ... program ...
    runtime.KeepAlive(&ballast)
}
```

The ballast is **virtually** allocated. Linux doesn't back untouched pages with RSS, so it does not consume physical memory — a clean advantage over adding a real global.

### 3. `GOMEMLIMIT` (Go 1.19+)

Set a soft memory cap; GC kicks in as usage approaches it.

```
GOMEMLIMIT=175MiB GOGC=off ./yourprog
```

When well-tuned, this replaces ballasts. The risk: set too low and GC runs almost continuously. Set it only if you actually know the ceiling; otherwise ballasts are more forgiving. Can be combined with `GOGC`.

## Ballast vs `GOMEMLIMIT` — which to use

| Situation | Pick |
|---|---|
| You know approx peak heap, want a hard-ish cap for ops | `GOMEMLIMIT` |
| You don't know peak heap, just want fewer cycles | ballast |
| You want both lower frequency and a safety ceiling | ballast + `GOMEMLIMIT` |
| Running on Linux and want the ballast to cost 0 RSS | ballast (untouched pages not backed) |

## Scanning cost — why big root sets can *help*

Since 1.18, root size contributes to target heap calculation. A program with a large goroutine stack or large pointer-containing global naturally spaces GC cycles further apart. This is worth knowing if you're considering pre-growing stacks or using a ballast — the effect is already baked in when the ballast is full of pointers or when worker goroutines have deep stacks.

## Fragmentation

The runtime uses a tcmalloc-style allocator and has good fragmentation behaviour by default. The book does not recommend defragmentation tricks; neither does this skill. The wins are in the allocation rate, not in arrangement.

## Practical checklist

Before reaching for `GOGC`/ballast/`GOMEMLIMIT`:

1. Profile: `go test -memprofile mem.pprof` → `go tool pprof -alloc_space`.
2. Attack the top sites. Usually it's string handling, `any` boxing, or preventable `make` in a loop.
3. Only after cutting easy allocations: consider knobs.
4. If you ship a knob (ballast or `GOMEMLIMIT`), document the expected live-heap range — next maintainer needs it to change it safely.
