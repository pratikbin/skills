# anti-patterns.md — pipeline smells and how to fix them

Common mistakes found in real Concourse pipelines. Each costs time, causes bugs, or creates false confidence. Ordered roughly by frequency.

## 1. Sequential gets at the top of the plan

The single most common speed killer. N gets in sequence run one after another; the plan cannot start its first task until the last get completes. Every job that starts with multiple `get` steps should wrap them in `in_parallel`.

```yaml
# WRONG
plan:
  - get: source
    trigger: true
  - get: ci
  - get: base-image
  - task: build ...

# RIGHT
plan:
  - in_parallel:
      fail_fast: true
      steps:
        - get: source
          trigger: true
        - get: ci
        - get: base-image
  - task: build ...
```

Fix: wrap in `in_parallel`. Add `fail_fast: true`. Use `limit:` if you have many gets and few workers. See `references/parallelism-patterns.md`.

## 2. `trigger: true` on every get in a fan-in

When a job depends on multiple upstream jobs finishing (fan-in), putting `trigger: true` on every get causes the job to run once per upstream job completion. If two upstreams finish for the same commit, the deploy job runs twice.

```yaml
# WRONG — two triggers means two runs when both unit and security-scan finish
- get: artifact
  trigger: true
  passed: [unit, security-scan]
- get: source
  trigger: true
  passed: [unit, security-scan]

# RIGHT — one trigger; source constrains without triggering
- get: artifact
  trigger: true
  passed: [unit, security-scan]
- get: source
  passed: [unit, security-scan]
```

Rule: in any fan-in job, exactly **one** get should have `trigger: true`. See `references/passed-chains.md`.

## 3. Missing `passed:` on fan-in gets (version skew)

When multiple gets should reference the same commit/version but only one has `passed:` set, Concourse fetches the latest version of the unconstrained resource — which may be from a different commit. The job runs with mismatched source and artifact, silently.

```yaml
# WRONG — artifact is from commit X (via unit), source is HEAD (might be commit Y)
- get: artifact
  passed: [unit]
  trigger: true
- get: source          # no passed: — drifts to latest
  
# RIGHT — both locked to the same build
- get: artifact
  passed: [unit]
  trigger: true
- get: source
  passed: [unit]
```

Always mirror `passed:` on every get that must be version-consistent. See `references/passed-chains.md`.

## 4. `serial: true` when `serial_groups:` is needed

`serial: true` prevents a job from running concurrently **with itself** (max 1 build at a time). It does nothing to prevent collision with **other jobs**. Two jobs that both deploy to staging and both have `serial: true` will still collide.

```yaml
# WRONG — serial: true on each job doesn't protect shared staging
- name: deploy-feature-a
  serial: true   # only prevents feature-a from running twice; won't stop feature-b collision
- name: deploy-feature-b
  serial: true

# RIGHT — shared group serializes across jobs
- name: deploy-feature-a
  serial_groups: [staging]
- name: deploy-feature-b
  serial_groups: [staging]
```

Use `serial: true` (or `max_in_flight: 1`) to throttle a single job. Use `serial_groups:` when multiple jobs must not run simultaneously. See `references/jobs.md`.

## 5. `across:` wrapping a `get` or `put` step

`across:` does not interpolate resource names. Trying to loop over resource names with `across:` either silently skips the step or produces a confusing error. The `get` name is not a runtime variable.

```yaml
# WRONG — does not work; resource names are not interpolated
- across:
    - var: env
      values: [dev, staging, prod]
  get: ((.:env))-database
  trigger: true

# RIGHT — use separate, explicit gets
- in_parallel:
    - get: dev-database
      trigger: true
    - get: staging-database
      trigger: true
    - get: prod-database
      trigger: true
```

`across:` is for task-level matrices over values, not for resource names. See `references/steps-flow.md`.

## 6. Unconditional `ensure` without `timeout`

`ensure` always runs — success, failure, error, abort. If the `ensure` step hangs (external API unresponsive, hung cleanup script), the entire build runner is blocked until the build is manually aborted. This compounds under load: many failed builds all blocked on hung `ensure` steps.

```yaml
# WRONG — cleanup can hang forever
ensure:
  task: cleanup-workspace
  file: ci/tasks/cleanup.yml

# RIGHT — bounded cleanup
ensure:
  task: cleanup-workspace
  file: ci/tasks/cleanup.yml
  timeout: 5m
```

Always add `timeout` to `ensure` steps. The same applies to all hooks (`on_failure`, `on_abort`, etc.). See `references/modifiers-hooks.md`.

## 7. Untagged retries hiding flakiness

`attempts: N` retries on both infrastructure errors and test failures. When applied to a test step that's genuinely flaky, it hides the flakiness and inflates build times. Every failed attempt runs the full test suite.

```yaml
# WRONG — tests shouldn't need retries; they should be fixed
- task: run-tests
  file: ci/tasks/test.yml
  attempts: 3

# RIGHT — add attempts only to infra-dependent steps; fix tests
- task: run-tests
  file: ci/tasks/test.yml
  timeout: 20m             # bound time; no retry
```

`attempts` is appropriate for steps hitting external APIs with genuine transient errors, not for test steps that should be deterministic.

## 8. `version: every` default surprises

`version: every` causes Concourse to process each unchecked version one build at a time. With a fast-moving git repo (hundreds of commits since last check), this queues hundreds of builds and works through them sequentially, potentially taking hours to catch up.

```yaml
# POTENTIALLY SURPRISING — high-commit-rate repos will queue a backlog
- get: source
  trigger: true
  version: every       # one build per commit

# USUALLY WHAT YOU WANT — catches up to HEAD, skips intermediate commits
- get: source
  trigger: true
  # version: latest is the default
```

Use `version: every` only when you explicitly need to process every commit (e.g., audit trail, per-commit changelog). Default is `latest`.

## 9. `set_pipeline` mixed with test jobs

Putting `set_pipeline` inside a job that also runs tests conflates two concerns: validating code and updating pipeline configuration. If the tests fail, the pipeline is not updated. If the pipeline update fails, tests might have passed but the job fails anyway.

```yaml
# WRONG — test failure blocks pipeline update; update failure looks like test failure
- name: validate-and-configure
  plan:
    - get: ci
      trigger: true
    - task: lint
      file: ci/tasks/lint.yml
    - task: test
      file: ci/tasks/test.yml
    - set_pipeline: self
      file: ci/pipelines/main.yml

# RIGHT — separate jobs; set_pipeline only runs after tests pass
- name: test-pipeline-config
  plan:
    - get: ci
      trigger: true
    - task: validate
      file: ci/tasks/validate-pipeline.yml

- name: reconfigure-self
  plan:
    - get: ci
      trigger: true
      passed: [test-pipeline-config]
    - set_pipeline: self
      file: ci/pipelines/main.yml
```

See `references/steps-meta.md`.

## 10. Runaway fan-out without `limit`

`in_parallel` without `limit` schedules all steps simultaneously. With 20+ steps, this can exhaust worker capacity, starve other pipelines, or trigger resource check storms.

```yaml
# POTENTIALLY RUNAWAY — 20 gets all at once
- in_parallel:
    steps:
      - get: service-a
      - get: service-b
      # ... 18 more services

# RIGHT — bounded concurrency
- in_parallel:
    limit: 4
    steps:
      - get: service-a
      - get: service-b
      # ... 18 more services
```

Rule of thumb: if you have more than 8-10 parallel steps, add `limit:`. See `references/parallelism-patterns.md`.

## 11. No `trigger:` anywhere in the pipeline

A pipeline with no `trigger: true` on any `get` step never runs automatically. Builds must be triggered manually via `fly trigger-job` or the UI. Common mistake when converting a manual-run pipeline to an automated one — developers add `passed:` to chain jobs but forget to add `trigger: true` to the entry point.

Scan: `grep -n 'trigger' pipeline.yml` — if it returns nothing or only `trigger: false` lines, the pipeline is manual-only.

## See also

- `references/parallelism-patterns.md` — how to fan-out correctly
- `references/passed-chains.md` — trigger vs constraint, version skew
- `references/jobs.md` — serial vs serial_groups
- `references/modifiers-hooks.md` — timeout on hooks
- `references/steps-flow.md` — across caveats
