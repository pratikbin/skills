---
name: go-optimizations-101
description: Use whenever the user writes, reviews, or profiles Go code and cares about performance — reducing allocations, escape-to-heap, GC pressure, bounds checks, function inlining, slice/string/map/channel/interface overhead, or any hot-path CPU/memory concern. Trigger on phrases like "optimize this Go code", "why does this allocate?", "why does this escape to heap?", "hot path", "reduce GC pressure", "benchmark shows X ns/op", "pprof shows", "make this faster", "this slice keeps growing", "this loop is slow", "too many allocations", and also proactively when writing new Go code that touches tight loops, high-throughput servers, serialization paths, or data-heavy pipelines. Based on Tapir Liu's *Go Optimizations 101* (Go 1.19 baseline).
---

# Go Optimizations 101

A practical optimization playbook for Go (official gc compiler, toolchain 1.19+). Tells you **what to change**, **why it helps**, and **when NOT to bother** — because most of the tricks in this skill hurt readability.

## When to use this skill

Use it when the user is doing any of:

- Writing hot-path code (tight loop, per-request server code, parser, encoder, data pipeline).
- Reviewing Go for performance (diff review, PR feedback, allocation audit).
- Diagnosing a concrete perf symptom: high `allocs/op`, long GC pauses, escape-analysis output, slow benchmark.
- Answering "why does this allocate / escape / copy / not inline?"

**Do NOT apply these patterns to cold code.** Readability > cleverness outside hot paths. The book (and this skill) is explicit about that.

## Core mental model

Every optimization in this skill falls into one of five levers:

| Lever | What it saves | Primary techniques |
|---|---|---|
| **Fewer allocations** | heap bytes + GC work | preallocate, reuse buffers, `sync.Pool`, clip before append, combine allocations |
| **Keep values on stack** | heap bytes + GC work | escape-analysis-aware code, avoid `interface{}` / `reflect.ValueOf` / closures capturing pointers, threshold tricks |
| **Lower GC pressure** | CPU + pauses | fewer short-lived allocs, larger long-lived roots → fewer cycles, `GOGC`/`GOMEMLIMIT`/ballast |
| **Fewer CPU ops per iter** | CPU | hoist loads out of loops, BCE hints, manual inlining, skip type boxing |
| **Better cache behavior** | CPU (memory-bound code) | smaller structs, field reordering, index tables, avoid pointer chasing |

When you're unsure which lever matters, run a benchmark with `-benchmem` first (see `scripts/bench_compare.sh`).

## Decision tree — pick the right reference

Match the user's symptom or question to a reference file, then read that file for concrete rules, code examples, and benchmark numbers.

```
Symptom / topic                                → Read first
────────────────────────────────────────────────────────────────────
"too many allocations" / benchmark allocs/op   → references/memory-allocations.md
                                                 + references/escape-analysis.md
"why does this escape to heap?"                → references/escape-analysis.md
"GC pause too long" / ballast / GOGC / GOMEMLIMIT
                                                → references/garbage-collection.md
"struct looks big" / field order               → references/structs.md
                                                 + references/value-sizes.md
"slice append slow" / "grow in one step"       → references/slices.md
"string concatenation slow"                    → references/strings.md
                                                 + references/bounds-check-elim.md
"bounds checks in benchmark"                   → references/bounds-check-elim.md
"map is hot"                                   → references/maps.md
"channel-heavy / select is slow"               → references/channels.md
"function doesn't inline" / "defer in loop"    → references/functions.md
"interface{} / type assertion overhead"        → references/interfaces.md
"loop over struct fields is slow"              → references/pointers.md
                                                 + references/structs.md
"function copies its arguments / big struct"   → references/value-sizes.md
```

For a conceptual intro to the model the rest of the book uses (value parts, direct vs indirect parts, copy costs), read `references/value-sizes.md` first — it's referenced everywhere else.

## Workflow for an optimization task

Pick the branch that matches what the user actually handed you.

### Branch A — full package available (can run tests + tools)

Follow this sequence. Skipping steps leads to guessing.

1. **Confirm it matters.** Ask: is this code on a hot path? If not, recommend leaving it alone.
2. **Measure first.** Before changing anything, capture a baseline: `go test -run=^$ -bench=. -benchmem -count=10` → `old.txt`. Use `benchstat` to compare later. Without numbers, you can't tell if a change helped.
3. **Classify the bottleneck.** `allocs/op > 0` → allocation problem. `B/op` much greater than payload → copy or large-struct problem. Both zero but slow → CPU problem (BCE, inline, bounds, math).
4. **Consult the right reference.** Use the decision tree above. Jump to the specific section that matches the symptom first; expand to more of the file only if that section's preconditions don't fit. Reading the whole file every time is expensive and usually unnecessary.
5. **Verify with escape analysis and the disassembler when relevant.**
   - Allocations/escapes: `scripts/escape_analysis.sh <pkg>` (wraps `go build -gcflags='-m -m'`).
   - Inlining: `scripts/inline_report.sh <pkg>` (`-gcflags='-m=2'`).
   - Bounds checks: `go build -gcflags="-d=ssa/check_bce/debug=1" ./...`.
6. **Re-measure.** Run the benchmark again → `new.txt`, then `benchstat old.txt new.txt`. If the change is within noise (< ~3%), revert it — the readability cost is not worth it.
7. **Note the trade-off in a comment** when the code is non-obviously shaped for performance. Explain **why**, not what. Future readers (including you) will otherwise "clean up" the optimization.

### Branch B — snippet-only or review-only (no runnable package, no benchmarks)

Common when reviewing a PR diff, answering "why does this allocate?", or tuning a code fragment the user pasted inline. You can't measure from here; be honest about that.

1. **Read what was handed to you once.** Don't invent context.
2. **Apply the decision tree** — pick one reference and read only the section that matches the symptom.
3. **Return a *reasoned* review**, structured as:
   - **Observed** — what's clearly a problem in the code shown (e.g., `fmt.Sprintf` in a hot loop, loop-variable address taken, unpre-allocated `append`).
   - **Hypothesis** — what would likely help, tied to a rule (cite the reference section).
   - **Verify** — the exact command the user should run to confirm (`scripts/escape_analysis.sh`, a benchmark, or `-gcflags='-m=2'`).
4. **Label hypotheses as hypotheses.** Do not claim a speedup number unless you actually measured it. "Expected to drop to 1 alloc/op" is fine; "2.5× faster" is not.
5. When you propose a rewrite in this mode, it's a **suggested patch**, not a promised optimization. Say so.

## Non-obvious traps (read these before proposing fixes)

These come up constantly and are easy to get wrong. Details live in the linked reference.

- **`strings.Builder` is not always the fastest string builder.** For many small concats, a preallocated `[]byte` can beat it. See `references/strings.md` §9.2.
- **`sync.Pool` can slow code down** if pooled items are small or rarely reused. See `references/memory-allocations.md` §3.9.
- **`defer` in a tight loop is a major cost.** Hoist it out or use a block-scoped anonymous function. See `references/functions.md` §13.5.
- **Taking `&slice[i]` inside a range loop** can make the loop variable escape. See `references/escape-analysis.md` §4.6.
- **`reflect.ValueOf(x)` forces `x` to heap.** Even reading a value through `reflect` can cost allocations. See `references/escape-analysis.md` §4.6.3.
- **Iterating a map by value** copies each value. For large values, iterate by key and index in. See `references/maps.md`.
- **Pointer-in-map / pointer-in-slice** makes the whole backing array a GC root set. For very large containers, consider indices into a slab. See `references/maps.md` §11.3, `references/garbage-collection.md` §5.8.
- **Small structs (≤ 2 words)** are passed/returned in registers — don't prematurely wrap them in pointers. See `references/structs.md` §7.2.
- **`interface{}` boxing** *may* allocate and typically forces an escape when the value is routed through `fmt`/`reflect` or retained past the current frame; pointer-sized values (pointers, maps, channels, funcs), zero-size values, constants, and some small integers box for free. Method calls through interfaces prevent inlining. See `references/interfaces.md` for the full cost table.

## Reviewer checklist (quick scan for PRs)

Drop-in checklist when reviewing a hot-path Go change:

- [ ] Is `make([]T, 0, N)` used when N is known? (`references/slices.md` §8.5–8.6)
- [ ] Any `append` on a slice we plan to alias? Add `slices.Clip` or `s[:len(s):len(s)]`. (§8.4, §8.13)
- [ ] `for i, v := range ...` where `v` is a big struct? Switch to `for i := range ...`. (§8.11)
- [ ] `defer` inside a loop? (§13.5)
- [ ] `fmt.Sprintf` / `+` string concat in a loop? Use `strings.Builder` or preallocated `[]byte`. (§9.2)
- [ ] Taking address of a loop variable and stashing it? Loop var escapes. (§4.6)
- [ ] `interface{}` parameter on a small, hot function? Usually worth a concrete version. (§14.4)
- [ ] Struct fields ordered widest-first? (§7.3)
- [ ] Index expressions `a[i]` in a loop where `i`'s max is known from a prior check? BCE-friendly form. (Chapter 10)
- [ ] Map cleared with `for k := range m { delete(m, k) }` on Go 1.11+? Fine. On older code, `m = make(...)` may be faster — check. (§11.1)
- [ ] `reflect.ValueOf` on a local? Forces escape. (§4.6.3)
- [ ] Function value call where the target is statically known? Inline manually or refactor to a direct call. (§13.1.2)

## Helper scripts

Located in `scripts/`. Prefer these over remembering the flag names.

- `scripts/escape_analysis.sh <pkg>` — per-line escape-analysis output, filtered to "escapes to heap" / "moved to heap" lines.
- `scripts/inline_report.sh <pkg>` — shows which functions the compiler inlined and which it skipped (with reason).
- `scripts/bce_check.sh <pkg>` — shows which bounds checks survived.
- `scripts/bench_compare.sh <pkg> <bench-regex>` — runs bench before + after your change, outputs `benchstat` diff.
- `scripts/alloc_profile.sh <pkg> <bench-regex>` — captures an alloc profile and prints the top sites.

Each script has a one-line usage comment at the top.

## Important caveats

- **Go version matters.** The book is calibrated to Go 1.19. Several patterns become unnecessary or outright wrong in 1.21+ (e.g., loop-variable semantics changed in 1.22; escape behavior of some `string`/`[]byte` conversions improved; `clear()` builtin landed). When unsure, re-measure on the Go version you actually ship. References call out version sensitivities inline.
- **Architecture matters.** Some tricks (small-struct-in-registers, stack-size thresholds) are specified for `GOARCH=amd64`. They still often help on `arm64`, but verify.
- **`unsafe` and `cgo` are out of scope.** The book deliberately excludes them; this skill follows that rule.
- **Benchmarks can lie.** Compiler can dead-code-eliminate work. Always consume results (`runtime.KeepAlive`, global sink, `b.ReportAllocs()`).

## Index of references

| File | Covers |
|---|---|
| `references/value-sizes.md` | Value parts, type sizes, alignments, struct padding, copy costs, copy scenarios |
| `references/memory-allocations.md` | Memory blocks, alloc places/scenarios, preallocation, combining allocs, sync.Pool |
| `references/escape-analysis.md` | Goroutine stacks, escape reasons, `-gcflags=-m`, thresholds, stack allocation tricks |
| `references/garbage-collection.md` | GC pacer, `GOGC`, `GOMEMLIMIT`, ballasts, fragmentation, root-set cost |
| `references/pointers.md` | Nil-check elision in loops, hoisting pointer dereferences |
| `references/structs.md` | Field order, small-struct register passing, pointer-field access in loops |
| `references/slices.md` | `make`/`append` internals, grow-in-one-step, clone, merge, clip, reset, 3-index subslice, index tables |
| `references/strings.md` | String↔[]byte conversion optimizations, concat strategies, `strings.Builder` traps |
| `references/bounds-check-elim.md` | BCE examples, hint patterns, BCE-friendly rewrites, known compiler misses |
| `references/maps.md` | Clear, pointers-in-maps cost, byte-array keys, grow-in-one-step, index tables |
| `references/channels.md` | Channels vs mutexes, single-channel patterns, optimized try-send/try-receive select |
| `references/functions.md` | Inlining rules, pointer vs value params, named results, defer-in-loop, arg evaluation order |
| `references/interfaces.md` | Boxing/unboxing, interface-to-interface alloc avoidance, interface method call cost |
