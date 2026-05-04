# Speeding Up Your `build-and-publish` Job

## What's happening

Your plan has 6 sequential `get` steps before any work starts. Each `get` downloads a resource version from a Concourse worker — they involve network I/O and container spin-up. Running them one at a time means you pay the cost of each serially. If each averages ~90 seconds (plausible for a Docker image or a git repo), that's 9 minutes before `unit` even begins — which matches your observation.

None of those gets depend on each other. There's no reason to serialize them.

## The fix: wrap all gets in `in_parallel`

```yaml
jobs:
  - name: build-and-publish
    plan:
      - in_parallel:
          fail_fast: true
          limit: 6
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

## Why this is safe

**Trigger behavior is unchanged.** `trigger: true` is a property of the `get` step itself, not of its position in the plan. Concourse's scheduler evaluates triggers on the resource version, not on where in the plan the `get` lives. Moving `app-src` inside `in_parallel` has no effect on when the job fires.

**No cold worker explosion.** With `limit: 6`, Concourse uses a semaphore: at most 6 of the gets run concurrently. Since you have 6 gets total, they all run at once — but this is 6 containers on your existing worker pool, not 6 new jobs. This is very different from splitting the gets into parallel *jobs* (which would compete for workers with everything else). All 6 gets here run within the same build, on the same worker, often on the same container if the resource type is the same.

**Implicit fan-in is preserved.** The `task: unit` step below `in_parallel` is not reached until *all* parallel gets succeed (or `fail_fast` short-circuits). There's no risk of a task starting before its inputs are ready.

## What each new keyword does

| Keyword | What it does |
|---|---|
| `in_parallel:` | Runs all child steps concurrently instead of sequentially. |
| `fail_fast: true` | If any one get fails (missing version, network error, deleted resource), the others are cancelled immediately. Without this, you'd wait for all gets to complete before the failure surfaces. |
| `limit: 6` | Caps the semaphore at 6 concurrent steps. With exactly 6 gets this has no practical effect right now, but it protects you if you add more gets later — you won't accidentally schedule more concurrent containers than you have workers. |

## Expected improvement

Instead of paying the sum of all 6 get durations, you pay the duration of the *slowest* single get. If the gets were costing you ~8 minutes collectively and the slowest individual one is 60–90 seconds, you're looking at a 5–7 minute reduction in wall-clock time before `unit` starts.

## If unit and build are also independent

If your `unit` task doesn't need the build artifact and `build` doesn't need the test results (they both just need the source), you can parallelize those too:

```yaml
      - in_parallel:
          fail_fast: true
          steps:
            - task: unit
              file: ci/tasks/unit/task.yml
            - task: build
              file: ci/tasks/build/task.yml
      - put: app-image
        params: { image: build/image.tar }
```

Only do this if they truly don't depend on each other's outputs.
