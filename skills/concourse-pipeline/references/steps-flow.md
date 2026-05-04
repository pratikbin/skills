# steps-flow.md — do, try, in_parallel, across

Composition steps that control how other steps execute: sequentially, optionally, in parallel, or across a value matrix.

## `do` schema

Run a list of steps sequentially. Primarily useful to group multiple steps inside a `try`, hook, or `across` body that only accepts a single step.

```yaml
- do:
    - task: step-one
      file: ci/tasks/one.yml
    - task: step-two
      file: ci/tasks/two.yml
```

`do` inside a `try`:

```yaml
- try:
    do:
      - task: optional-lint
        file: ci/tasks/lint.yml
      - task: optional-format-check
        file: ci/tasks/format.yml
```

## `try` schema

Run a step; if it fails, continue the plan rather than failing the build.

```yaml
- try:
    task: notify-external-system
    file: ci/tasks/notify.yml
```

Use `try` for steps where failure is acceptable (notification side-effects, optional cache warm). Do NOT use it to suppress real errors silently — add an `on_failure` to at least log.

## `in_parallel` schema

```yaml
- in_parallel:
    fail_fast: false       # optional; abort remaining steps when any step fails (default: false)
    limit: null            # optional; semaphore cap on concurrent running steps (default: unlimited)
    steps:                 # required; list of steps to run concurrently
      - get: source
      - get: ci
      - task: preflight
        file: ci/tasks/preflight.yml
```

Short form (no options needed):

```yaml
- in_parallel:
    - get: source
    - get: ci
```

## `across` schema

Run the body step once per combination of values. Produces a build matrix.

```yaml
- across:
    - var: go_version           # required; local var name (reference as ((.:go_version)))
      values: ["1.21", "1.22", "1.23"]
      max_in_flight: all        # optional per-var; integer or "all"
    - var: os
      values: ["linux", "darwin"]
      max_in_flight: 2
  max_in_flight: all            # top-level; overrides per-var if set; integer or "all"
  fail_fast: true               # optional; abort remaining combinations on first failure
  do:                           # body — usually a do or single task step
    - task: test
      file: source/ci/test.yml
      vars:
        go: ((.:go_version))
        os: ((.:os))
```

### `across` hard limits

- Does **not** work with `get` or `put`. Resource names are not interpolated inside across. This fails:
  ```yaml
  # WRONG — does not work
  - across:
      - var: env
        values: [staging, prod]
    get: ((.:env))-credentials
  ```
- Outputs produced inside `across` do **not** escape to the outer plan. Use `put` to persist results externally.
- `max_var_values` (optional per-var field): reject configs with more values than this limit — a safety check to prevent runaway matrices.

## Examples

### `in_parallel` fan-out gets — fastest single change

The most impactful parallelism win in most pipelines:

```yaml
jobs:
  - name: build
    plan:
      - in_parallel:
          fail_fast: true
          steps:
            - get: source
              trigger: true
            - get: ci
            - get: base-image
            - get: version
      - task: compile
        file: ci/tasks/compile.yml
```

All inputs fetch concurrently. Without `in_parallel`, four sequential gets run one at a time.

### Parallel test shards

```yaml
- in_parallel:
    fail_fast: true
    steps:
      - task: test-unit
        file: ci/tasks/unit.yml
        image: test-image
      - task: test-integration
        file: ci/tasks/integration.yml
        image: test-image
      - task: test-e2e
        file: ci/tasks/e2e.yml
        image: test-image
```

Three suites run simultaneously. `fail_fast: true` aborts the others as soon as one fails, saving worker time.

### `across` + nested `in_parallel` — parallel matrix

Get inputs once outside `across`; run the matrix body in parallel per combination:

```yaml
- get: source
  trigger: true
- across:
    - var: go_version
      values: ["1.21", "1.22", "1.23"]
    - var: os
      values: ["linux", "darwin"]
  max_in_flight: all
  fail_fast: true
  do:
    - in_parallel:
        fail_fast: true
        steps:
          - task: test
            file: source/ci/test.yml
            vars:
              go: ((.:go_version))
              os: ((.:os))
          - task: vet
            file: source/ci/vet.yml
            vars:
              go: ((.:go_version))
              os: ((.:os))
```

6 combinations × 2 tasks = 12 concurrent task runs. `fail_fast: true` at both levels bails early.

### `try` for optional notification

```yaml
- task: deploy
  file: ci/tasks/deploy.yml
- try:
    task: post-deploy-notify
    file: ci/tasks/slack.yml
    params:
      WEBHOOK: ((slack_webhook))
```

Deploy must succeed; Slack notification failure doesn't fail the build.

## Gotchas

- `across` with a `get` or `put` step at the body level is silently ignored or errors — the resource name is not var-interpolated. Fetch inputs before `across`.
- Outputs from inside `across` do not propagate outward. If you need to collect results, write them to an external store via `put` inside the across body.
- `in_parallel` with no `limit` and many steps can saturate workers. If you have 20+ steps, set `limit: 4` or so.
- `fail_fast: true` on `in_parallel` cancels still-running steps when the first fails. The build itself fails only after cleanup. Running steps are interrupted, not killed immediately.
- `try` swallows errors silently. Always pair with an `on_failure` or logging if you need to know when it fires.
- `do` at the top level of a plan is redundant — the plan itself is already a sequence. Use `do` only inside other steps.

## See also

- `references/parallelism-patterns.md` — when and how much to parallelize
- `references/steps-task.md` — task step within in_parallel/across
- `references/modifiers-hooks.md` — timeout/attempts/ensure on in_parallel
