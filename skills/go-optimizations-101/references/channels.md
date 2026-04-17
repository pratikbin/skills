# Channels

Channels are ergonomic. They are not always the fastest synchronization primitive. Use them when the semantics they give you (ownership transfer, cancelation propagation, clean fan-in/fan-out) are worth the cost. If you're only protecting a counter or a flag, use atomics or a mutex.

## 12.1 — Don't use a channel where a mutex or atomic would do

Measured (1.19) on "increment a shared int":

| Method | ns/op |
|---|---|
| no sync | 2.25 |
| `atomic.AddInt32` | 7.11 |
| `sync.Mutex` | 14.25 |
| channel semaphore | 61.44 |

Order of preference for protecting a small value:
1. Don't share it at all — pass by copy, use per-goroutine state and merge at the end.
2. `sync/atomic` — cheapest when operations are single-word.
3. `sync.Mutex` — when operations span multiple fields.
4. Channel — when you need the ordering/ownership semantics (only-one-goroutine-holds-the-value-at-a-time).

## 12.2 — One channel beats several, because `select` with more cases is slower

Each additional `case` in a `select` block costs CPU. A one-case `select` is treated by the compiler as a plain channel op (no select machinery).

Measured:

```
Benchmark_Select_OneCase   58.9 ns/op
Benchmark_Select_TwoCases 115.3 ns/op
```

### When you have two logical channels carrying different message types, consider one channel of a union type

```go
// slower — two channels, two-case select
var x = make(chan int)
var y = make(chan string)
select {
case vx = <-x:
case vy = <-y:
}
// 1295 ns/op in the book's benchmark

// faster — one channel, type switch
var x = make(chan any)
v := <-x
switch v := v.(type) {
case int:    vx = v
case string: vy = v
}
// 941 ns/op

// fastest — one channel, struct with discriminator
type T struct{ x int; y string }
var x = make(chan T)
v := <-x
if v.y != "" { vy = v.y } else { vx = v.x }
// 851 ns/op
```

Choose struct-union over `any`-based when:
- Message kinds are fixed (not pluggable).
- Allocations matter (`any` boxes small values).

Choose `any`-based when:
- Message types are many or may change.
- Type-switch discrimination is cleaner than field-set discrimination.

## 12.3 — Try-send / try-receive (`select` with one case + default) is specially optimized

The compiler recognizes the shape `select { case <-c: default: }` (and its send counterpart) and compiles it to a fast path — not the full select machinery.

Measured:

```
Benchmark_TryReceive  5.65 ns/op
Benchmark_TrySend     5.29 ns/op
```

Compare to a blocking channel op at ~60 ns/op — try-send/receive is ~10× cheaper because it never parks the goroutine.

### Useful shapes

```go
// Non-blocking drain
for {
    select {
    case <-c:
    default:
        return
    }
}

// Non-blocking signal (send, but OK if nobody's listening)
select {
case c <- struct{}{}:
default:
}

// Quick close-check in a loop (don't block if closed channel isn't quick to read)
select {
case <-ctx.Done():
    return ctx.Err()
default:
}
```

Cancel-check via context: `ctx.Done()` is a channel; use try-receive or pair with the real select case.

## Practical rules

- **Tiny counters/flags**: `atomic.Int32` or `sync.Mutex`. Not channels.
- **Producer/consumer handoff**: channel with an adequate buffer.
- **Fan-in of different message types**: one channel of a struct, with a type/field discriminator, instead of a multi-case select.
- **Non-blocking polling**: try-send / try-receive. Very cheap.
- **Select with many cases**: if you're hitting three or more regularly-active cases in a hot path, the cost is noticeable — consider architectural changes (merging, or moving some branches to atomics/mutexes).

## Review checklist

- [ ] Is a channel used where an atomic or mutex would work? (simple counters, flags)
- [ ] Any `select` with 3+ cases in a hot loop? Can it be reduced?
- [ ] Is the channel `struct{}`-typed for signaling? (avoids value copy)
- [ ] Unbuffered channel where a 1-deep buffer would avoid unnecessary parking?
- [ ] Try-send / try-receive idiom for poll-style loops?
