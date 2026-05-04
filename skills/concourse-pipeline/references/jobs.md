# jobs.md — job configuration schema

Job is the unit of scheduling in Concourse. A job has a name, a plan, and optional concurrency/retention/lifecycle controls.

## Schema

```yaml
jobs:
  - name: my-job                    # required; unique identifier
    plan: []                        # required; ordered list of steps
    serial: false                   # default false; forces max_in_flight: 1 (no parallel runs)
    serial_groups: []               # list of group names; jobs sharing a group run serially
    max_in_flight: null             # integer; max concurrent builds of this job (null = unlimited)
    build_logs_to_retain: null      # integer shorthand; keep N most recent build logs
    build_log_retention:            # structured form; takes precedence over build_logs_to_retain
      builds: 50                    # keep last N builds
      days: 30                      # keep builds from last N days
      minimum_succeeded_builds: 1   # never drop below N succeeded builds regardless of age
    disable_manual_trigger: false   # default false; when true, "+" button is hidden in UI
    interruptible: false            # default false; when true, new build of this job aborts older pending one
    public: false                   # default false; when true, build output visible without login
    on_success:                     # step to run if plan succeeds
    on_failure:                     # step to run if plan fails
    on_error:                       # step to run if Concourse itself errors (infra/worker issue)
    on_abort:                       # step to run if build is aborted by a user or auto-abort
    ensure:                         # step that always runs — success, failure, error, or abort
```

### Concurrency controls compared

| Control | Scope | Effect |
|---|---|---|
| `serial: true` | this job | same as `max_in_flight: 1`; one build at a time |
| `max_in_flight: N` | this job | at most N concurrent builds |
| `serial_groups: [X]` | jobs sharing group X | all listed jobs collectively run one at a time |

`serial_groups` and `serial`/`max_in_flight` are not mutually exclusive — groups take effect across jobs, max_in_flight within a single job.

## Examples

### `serial_groups` — prevent staging collision

Two jobs both deploy to staging. Without coordination they race. Put them in the same serial group:

```yaml
jobs:
  - name: deploy-feature-a
    serial_groups: [staging]
    plan:
      - get: feature-a
        trigger: true
      - task: deploy
        file: ci/tasks/deploy-staging.yml
        params:
          APP: feature-a

  - name: deploy-feature-b
    serial_groups: [staging]
    plan:
      - get: feature-b
        trigger: true
      - task: deploy
        file: ci/tasks/deploy-staging.yml
        params:
          APP: feature-b
```

Both jobs run freely in isolation. When both trigger at the same time, one queues until the other finishes. The staging environment is never hit by both at once.

### `max_in_flight` — throttle DB migrations

A migration job is slow and idempotent but cannot run concurrently (advisory locks). Default is unlimited; `serial: true` allows only one. `max_in_flight: 2` is a softer middle ground for jobs that are safe to overlap up to N:

```yaml
jobs:
  - name: run-migrations
    max_in_flight: 1          # treat DB migration as a critical section
    plan:
      - get: migrations
        trigger: true
      - task: migrate
        file: ci/tasks/migrate.yml
```

Use `max_in_flight: 1` here instead of `serial: true` because the intent is a concurrency cap, not job-to-job serialization. Semantics are identical but the distinction signals intent.

### `build_log_retention` — bounded log storage

Keep last 50 builds OR last 30 days, but never drop the last succeeded build:

```yaml
jobs:
  - name: nightly-report
    build_log_retention:
      builds: 50
      days: 30
      minimum_succeeded_builds: 1
    plan:
      - task: generate-report
        file: ci/tasks/report.yml
```

### `interruptible` — don't block the queue on stale CI builds

Long-running PR validation jobs can pile up. Mark them interruptible so a new push replaces the old pending build:

```yaml
jobs:
  - name: pr-validate
    interruptible: true
    plan:
      - get: pr
        trigger: true
      - task: lint
        file: ci/tasks/lint.yml
      - task: test
        file: ci/tasks/test.yml
```

## Gotchas

- `serial: true` and `serial_groups: [X]` together is redundant — the group wins. Don't add both.
- A job with `disable_manual_trigger: true` can still be triggered by `get: … trigger: true` or by `fly trigger-job`. It only hides the UI button.
- `on_success`/`on_failure`/`on_error`/`on_abort`/`ensure` at job level apply to the entire plan as if the plan were a single step. For step-level hooks see `references/modifiers-hooks.md`.
- `interruptible` only aborts pending builds, not running ones. A running build must finish or be manually aborted.
- `build_logs_to_retain` is deprecated in favor of `build_log_retention` (structured form). Both work but don't use both on the same job.

## See also

- `references/steps-flow.md` — `in_parallel`, `do`, `try`, `across` inside plan
- `references/modifiers-hooks.md` — step-level hooks and modifiers
- `references/parallelism-patterns.md` — tuning max_in_flight, serial_groups for throughput
