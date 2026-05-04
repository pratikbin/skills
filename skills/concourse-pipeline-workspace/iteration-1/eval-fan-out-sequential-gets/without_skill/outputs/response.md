# Speeding Up Concourse Pipeline with Parallel Gets

## The Problem

Your pipeline runs all `get` steps sequentially because they're listed at the same indentation level inside `plan` without any parallelism directive. Concourse executes `plan` steps one-by-one by default. Each `get` waits for the previous one to finish before starting — even though there's no data dependency between them.

With 5 independent resource fetches before the first `task`, you're paying serial latency for work that could all happen at once.

## The Fix: `in_parallel`

Concourse has a first-class `in_parallel` step type that runs a list of steps concurrently on the same worker (or across workers if `limit` is set). It waits for all child steps to complete before proceeding to the next plan step.

```yaml
jobs:
  - name: build-and-publish
    plan:
      - in_parallel:
          steps:
            - get: app-src
              trigger: true
            - get: ci
            - get: golang-builder
            - get: deploy-keys
            - get: chart-repo
            - get: version
      - task: unit
        file: ci/tasks/unit/task.yml
      - task: build
        file: ci/tasks/build/task.yml
      - put: app-image
        params: { image: build/image.tar }
```

## Why This Is Safe

**Trigger behavior is preserved.** The `trigger: true` on `app-src` works the same way regardless of whether `get` is inside `in_parallel` or at the top level. Concourse evaluates trigger conditions on the resource check cycle, not at plan execution time. Wrapping it in `in_parallel` does not suppress or alter triggering.

**No worker explosion.** `in_parallel` by default runs all steps on the same worker that accepted the build. It does not dispatch separate workers per step. You won't burn 6 workers on 6 `get` calls — they all run on the worker that picked up the build, using goroutines within the worker process. If you're worried about throttling, you can add `limit: 3` under `in_parallel` to cap concurrency, but for 6 lightweight resource fetches it's typically unnecessary.

**Step ordering still enforced.** `in_parallel` is a single logical step in the outer `plan`. The tasks and `put` that follow it will not start until every `get` inside `in_parallel` has completed successfully. If any `get` fails, the parallel group fails and the build stops — same behavior as today.

**Artifact availability is unchanged.** All resources fetched inside `in_parallel` are available in the build's working directory for subsequent tasks, exactly as if they were fetched sequentially.

## Optional: `fail_fast`

If one resource fetch fails and you want the others to abort immediately rather than wait to finish, add `fail_fast: true`:

```yaml
      - in_parallel:
          fail_fast: true
          steps:
            - get: app-src
              trigger: true
            - get: ci
            - get: golang-builder
            - get: deploy-keys
            - get: chart-repo
            - get: version
```

This is purely a latency optimization for the failure case — it has no effect on the success path.

## Expected Impact

Your 6 sequential `get` steps likely each take 30–90 seconds depending on resource type and cache state. Running them in parallel collapses that to the duration of the slowest single `get`. If the slowest is 60 seconds and the others average 45 seconds, you go from ~5–6 minutes of serial fetching down to ~60–90 seconds — the bulk of your 9-minute build time eliminated without touching the actual build logic.
