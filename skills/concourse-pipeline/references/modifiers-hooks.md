# modifiers-hooks.md — timeout, attempts, tags, and lifecycle hooks

Step modifiers change how a step executes. Hooks run additional steps based on the outcome of the parent step.

## Modifiers schema

```yaml
- task: my-task
  file: ci/tasks/task.yml
  timeout: 30m             # optional; duration string; fail the step if it exceeds this
  attempts: 3              # optional; integer ≥ 1; retry up to N times on error or failure
  tags: [special-worker]   # optional; list of worker tags; schedule this step on tagged workers
```

### `timeout`

Duration string: `1h`, `30m`, `90s`, `2h30m`. Applies to the step itself, not to its hooks. When the step times out, it is treated as a failure — `on_failure` fires, not `on_error`.

Always add `timeout` to:
- Any step that calls an external API (deploys, notifications, external DB migrations).
- Any `ensure` or hook step — a hung hook hangs the entire build indefinitely.
- Tasks that can deadlock (tests with missing timeouts, integration tests waiting on infra).

### `attempts`

Retries the step up to N total attempts (first attempt + N-1 retries). Concourse retries on **both** build failure and on Concourse infrastructure errors. When all attempts are exhausted without success, the step fails.

```yaml
- task: flaky-integration-test
  file: ci/tasks/integration.yml
  attempts: 3              # try up to 3 times; fail on third consecutive failure
  timeout: 10m             # each attempt capped at 10 minutes
```

Use sparingly. Retrying hides flakiness rather than fixing it. Appropriate for tests with genuine infrastructure noise (network-dependent, cloud API rate limits).

### `tags`

List of worker tags. The step is only scheduled on workers that advertise all listed tags. Common use: GPU workers, privileged build pools, regional workers.

```yaml
- task: gpu-inference
  file: ci/tasks/infer.yml
  tags: [gpu, us-east-1]
```

## Hooks schema

Hooks run as a separate step after the parent step completes. They receive the same artifacts (inputs) as the parent. They can run tasks, puts, and most other step types.

```yaml
- task: deploy
  file: ci/tasks/deploy.yml
  on_success:              # runs if step exits 0
    task: smoke-test
    file: ci/tasks/smoke.yml
  on_failure:              # runs if step exits non-zero (task script returned failure)
    task: notify-failure
    file: ci/tasks/slack.yml
  on_error:                # runs if Concourse infrastructure fails (worker crash, container error)
    task: alert-ops
    file: ci/tasks/pagerduty.yml
  on_abort:                # runs if a user aborts the build or auto-abort triggers
    task: rollback
    file: ci/tasks/rollback.yml
  ensure:                  # always runs regardless of outcome (success, failure, error, abort)
    task: cleanup
    file: ci/tasks/cleanup.yml
```

### Hook firing conditions

| Hook | Fires when |
|---|---|
| `on_success` | step exits 0 (success) |
| `on_failure` | step exits non-zero (build failure — the script/task said "fail") |
| `on_error` | Concourse infrastructure error (worker died, container failed to start, timeout) |
| `on_abort` | build was cancelled by a user or interruptible job replaced it |
| `ensure` | always — success, failure, error, AND abort |

Key distinction: **`on_failure` ≠ `on_error`**. `on_failure` is the application saying it failed. `on_error` is Concourse infrastructure failing. A hanging test that times out fires `on_failure` (timeout is a failure). A worker that crashes mid-task fires `on_error`.

**`ensure` vs `on_abort`**: `on_abort` only runs on abort. `ensure` runs on abort **and** every other outcome. Use `ensure` for cleanup that must happen no matter what. Use `on_abort` for rollback that is only meaningful after a partial apply.

### Hooks share artifacts

Hooks have access to the same input artifacts as the parent step. A `task` hook can read files written by the parent step. This is how rollback hooks read the deployment state written by the deploy task.

## Examples

### Slack notification on failure

```yaml
- task: run-tests
  file: ci/tasks/test.yml
  timeout: 20m
  on_failure:
    task: notify-slack
    file: ci/tasks/notify.yml
    params:
      WEBHOOK: ((slack_webhook))
      MESSAGE: "Tests failed on $BUILD_PIPELINE_NAME/$BUILD_JOB_NAME"
```

### Rollback on abort

```yaml
- task: deploy-prod
  file: ci/tasks/deploy.yml
  timeout: 15m
  on_abort:
    task: rollback
    file: ci/tasks/rollback.yml
    timeout: 5m              # hooks need their own timeout — they can also hang
```

`on_abort` is appropriate here: if someone manually cancels a deployment, rollback to the previous state. If the deploy fails (non-abort), the pipeline should investigate rather than auto-rollback.

### `ensure` for mandatory workspace cleanup

```yaml
- task: provision-test-db
  file: ci/tasks/provision.yml
  ensure:
    task: destroy-test-db
    file: ci/tasks/destroy.yml
    timeout: 5m              # always timeout ensures, or a hung DB destroy blocks the runner
```

`ensure` fires even if `provision-test-db` itself fails or is aborted. Without it, test databases accumulate on failure paths.

### Combining hooks

```yaml
- task: integration
  file: ci/tasks/integration.yml
  timeout: 30m
  attempts: 2
  on_failure:
    do:
      - task: capture-logs
        file: ci/tasks/capture-logs.yml
      - task: notify-team
        file: ci/tasks/slack.yml
  ensure:
    task: cleanup-infra
    file: ci/tasks/cleanup.yml
    timeout: 3m
```

`on_failure` fires only on test failure; `ensure` fires on all outcomes. Each is a separate step.

## Gotchas

- Hooks do **not** have their own `timeout` by default — they inherit none from the parent. A notification hook calling an unresponsive Slack endpoint will hang forever. Always add `timeout` to hooks.
- `attempts` retries after **both** failure and error. If a task is broken (always exits 1), `attempts: 3` runs it 3 times uselessly. Fix the underlying issue, don't paper over it with retries.
- `ensure` runs even after `on_failure` or `on_error` hooks. Order: parent runs → outcome-specific hook runs → `ensure` runs.
- Hook steps access the same artifact directory as the parent step. Files written by the parent ARE visible to hooks. Files written by a hook are NOT visible to the next step in the plan (hooks don't contribute to the plan's output flow).
- `on_abort` does **not** fire when `interruptible: true` replaces an old build — use `ensure` for cleanup in interruptible jobs.

## See also

- `references/jobs.md` — job-level on_failure/on_abort/ensure (same hooks, wraps entire plan)
- `references/steps-flow.md` — `try` step as alternative to swallowing failures
- `references/parallelism-patterns.md` — `in_parallel` with `fail_fast` vs hooks
