# time-resource.md — `time` resource type schema and patterns

Emits a version on a schedule (interval) or within a time window (start/stop). Use to rate-limit or schedule jobs.

---

## Schema

```yaml
resources:
  - name: every-night
    type: time
    source:
      interval: 24h              # optional; how often to emit a new version
      start: "10:00 PM"          # optional; window open time (24h or 12h format)
      stop: "11:00 PM"           # optional; window close time
      location: America/New_York # optional; IANA timezone; default UTC
      days:                      # optional; restrict to specific days
        - Monday
        - Tuesday
        - Wednesday
        - Thursday
        - Friday
      initial_version: true      # optional; emit a version at pipeline apply time (before first tick)
```

Fields:

| field | type | notes |
|---|---|---|
| `interval` | duration | `"1h"`, `"24h"`, `"168h"` (week); emits one version per interval |
| `start` | time string | window open; requires `stop` |
| `stop` | time string | window close; requires `start` |
| `location` | IANA timezone | applies to `start`/`stop` and `days`; default `UTC` |
| `days` | list of day names | `Monday`…`Sunday`; restrict window to these days only |
| `initial_version` | bool | emit a synthetic version at pipeline apply time; allows manual runs before the first tick |

Combining `interval` + `start`/`stop`: the resource emits at most one version per `interval`, and only within the window. If the interval fires outside the window, no version is emitted until the window is next open.

---

## The big gotcha — every tick triggers downstream

```yaml
resources:
  - name: every-5m
    type: time
    source:
      interval: 5m

jobs:
  - name: heavy-job
    plan:
      - get: every-5m
        trigger: true    # fires heavy-job EVERY 5 minutes
      - task: run-heavy-work
```

Every `interval` tick produces a new version. With `trigger: true`, the job runs on every version. If the job takes longer than the interval, runs queue up. Use `interval` values that match the job's actual cadence, not the fastest you'd ever want to run.

---

## Examples

### Nightly build — 2am UTC, Monday–Friday

```yaml
resources:
  - name: nightly-trigger
    type: time
    source:
      start: "2:00 AM"
      stop: "3:00 AM"
      location: UTC
      days:
        - Monday
        - Tuesday
        - Wednesday
        - Thursday
        - Friday

jobs:
  - name: nightly-build
    plan:
      - get: nightly-trigger
        trigger: true
      - task: run-nightly-suite
        # ...
```

One version is emitted per window entry. The job will fire once per weekday night.

---

### Business-hours-only build — any commit, but only process during business hours

```yaml
resources:
  - name: source
    type: git
    source:
      uri: https://github.com/example/app.git
      branch: main

  - name: business-hours
    type: time
    source:
      start: "9:00 AM"
      stop: "6:00 PM"
      location: America/Los_Angeles
      days: [Monday, Tuesday, Wednesday, Thursday, Friday]
      initial_version: true

jobs:
  - name: gated-deploy
    plan:
      - get: source
        trigger: true
        passed: [test]
      - get: business-hours    # this get does NOT trigger the job
        trigger: false
      - task: deploy
        # ...
```

The `business-hours` resource is fetched but not set as a trigger. It acts as a gate: the task step can inspect the current time or you add a manual approval. To make it a hard gate, use `trigger: true` on `business-hours` and remove it from `source`.

---

### Monthly run — first of the month

```yaml
resources:
  - name: monthly
    type: time
    source:
      interval: 720h            # ~30 days; not exact; use start/stop for precision
      start: "12:00 AM"
      stop: "1:00 AM"
      location: UTC

jobs:
  - name: monthly-cleanup
    plan:
      - get: monthly
        trigger: true
      - task: cleanup
        # ...
```

For exact day-of-month scheduling, combine with an external cron trigger and `webhook_token` on the resource.

---

## Gotchas

- `interval` alone with `trigger: true` fires the job every single tick. Small intervals on slow jobs cause queue buildup.
- `start`/`stop` with no `interval` emits at most one version per window entry (when the window opens). The job fires once per window.
- `initial_version: true` is required if you want to be able to trigger the job manually before it has ever fired. Without it, `fly trigger-job` on a job gated by a time resource will queue but won't find any version to satisfy the get.
- Time format: `"9:00 AM"` and `"09:00"` both work. Mixed 12h/24h in the same resource is valid.
- `days` filtering is applied in the configured `location` timezone.
- There is no way to emit a version at a specific time of day with `interval` alone — use `start`/`stop` for that.

---

## See also

- [trigger-tuning.md](trigger-tuning.md) — `check_every` vs time resource, webhook alternative
- [versioning.md](versioning.md) — `trigger: true` mechanics
- [anti-patterns.md](anti-patterns.md) — `interval: 1m` driving heavy jobs
