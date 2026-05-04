# parallelism-patterns.md — fan-out, shards, matrices, tuning

Three places parallelism pays off, in order of bang-for-buck: (a) fan-out the gets at the plan top, (b) parallelize independent tasks, (c) build matrices with `across`. Sequential gets are the single most common reason pipelines feel slow.

## Pattern 1: Fan-out gets (always)

Concourse docs: "Using the `in_parallel` step where possible is the easiest way to speeding up builds."

Every job that starts with multiple `get` steps should wrap them in `in_parallel`. The individual gets have no dependencies on each other; running them sequentially is pure waste.

**Before (sequential — wrong default):**

```yaml
plan:
  - get: source
    trigger: true
  - get: ci
  - get: base-image
  - get: version
  - task: build
    file: ci/tasks/build.yml
```

With 4 gets averaging 10s each, the plan wastes ~30s before `build` starts.

**After (parallel — correct):**

```yaml
plan:
  - in_parallel:
      fail_fast: true
      limit: 4
      steps:
        - get: source
          trigger: true
        - get: ci
        - get: base-image
        - get: version
  - task: build
    file: ci/tasks/build.yml
```

All 4 fetch concurrently. Plan starts `build` as soon as the slowest get finishes, not the sum of all.

`fail_fast: true` bails immediately if any input is missing (e.g., the resource was deleted). Without it, the other gets proceed even though the build will fail anyway. `limit` caps concurrency if you have many gets and few workers.

## Pattern 2: Parallel test shards

Independent test suites run in `in_parallel`. No `limit` needed unless you have 10+ shards or low worker count.

```yaml
plan:
  - in_parallel:
      - get: source
        trigger: true
      - get: test-image
  - in_parallel:
      fail_fast: true
      steps:
        - task: unit
          file: source/ci/unit.yml
          image: test-image
        - task: integration
          file: source/ci/integration.yml
          image: test-image
        - task: lint
          file: source/ci/lint.yml
          image: test-image
  - task: publish-results
    file: source/ci/publish.yml
```

First `in_parallel`: fan-out gets. Second: parallel test shards. `publish-results` runs after all shards pass (or `fail_fast` short-circuits). 

## Pattern 3: Build matrix with `across`

Fetch inputs once, run the matrix body per combination.

```yaml
plan:
  - in_parallel:
      - get: source
        trigger: true
      - get: ci
  - across:
      - var: go_version
        values: ["1.21", "1.22", "1.23"]
      - var: os
        values: ["linux", "darwin"]
    max_in_flight: all        # run all 6 combinations in parallel
    fail_fast: true
    do:
      - task: test
        file: source/ci/test.yml
        vars:
          go: ((.:go_version))
          os: ((.:os))
        params:
          GOOS: ((.:os))
```

`max_in_flight: all` at the across level runs all combinations simultaneously. For large matrices (>12 combinations) consider an integer limit to avoid saturating the worker pool.

## Pattern 4: Fan-in after matrix (parallel shards → single publish)

```yaml
plan:
  - get: source
    trigger: true
  - in_parallel:
      fail_fast: true
      steps:
        - task: test-amd64
          file: source/ci/test.yml
          params: { GOARCH: amd64 }
        - task: test-arm64
          file: source/ci/test.yml
          params: { GOARCH: arm64 }
  - task: publish
    file: source/ci/publish.yml
```

`publish` only runs after both shards succeed. This is implicit fan-in: the task after `in_parallel` waits for all parallel steps. See `references/passed-chains.md` for multi-job fan-in.

## `max_in_flight` tuning

`max_in_flight` at the job level caps concurrent builds of a single job. At the `across` level it caps concurrent combinations.

| Scenario | Setting |
|---|---|
| DB migration (must not overlap) | `max_in_flight: 1` (or `serial: true`) |
| Resource-hungry build (2 safe) | `max_in_flight: 2` |
| Large test matrix, limited workers | `max_in_flight: 4` |
| Fast matrix, many workers | `max_in_flight: all` |

Default is unlimited. Tighten only when protecting shared external state or when worker saturation is observed.

## Real-world example: concourse/ci k8s-check-helm-params

From `concourse/ci` release pipeline — fan-out gets with passed constraints:

```yaml
- name: k8s-check-helm-params
  public: true
  serial: true
  plan:
    - in_parallel:
        - get: concourse
          passed: [build-rc-image]
          trigger: true
        - get: concourse-rc-image
          passed: [build-rc-image]
          trigger: true
        - get: version
          passed: [build-rc-image]
          trigger: true
        - get: unit-image
        - get: concourse-chart
          trigger: true
        - get: linux-rc
          resource: linux-amd64-rc
          passed: [bin-smoke]
          trigger: true
        - get: ci
    - task: check-params
      file: ci/tasks/check-distribution-env/task.yml
      image: unit-image
      input_mapping:
        distribution: concourse-chart
      params:
        DISTRIBUTION: helm
```

Seven gets, all parallel, before a single task. This is the pattern.

## Gotchas

- `in_parallel` without `fail_fast: true` in a fan-out get block means all gets complete even when one fails. You'll wait the full duration of the slowest get before the build fails. Add `fail_fast: true` to fail fast.
- `across` with many values and `max_in_flight: all` can schedule N*M tasks simultaneously. With 4 vars × 5 values each = 625 combinations — set an integer limit.
- `limit` on `in_parallel` is a semaphore, not a work queue size. With `limit: 2` and 10 steps, 2 run at a time and the rest wait. Build time is roughly `ceil(N/2) × avg_step_time`.
- Parallelism inside a single job competes with other jobs for workers. If your cluster is small, unlimited parallelism in one job starves others.
- There's no benefit to `in_parallel` for a single step. The wrapper adds overhead without gain.

## See also

- `references/passed-chains.md` — multi-job fan-in using `passed:` across jobs
- `references/steps-flow.md` — `across`, `in_parallel`, and `do` schemas
- `references/jobs.md` — `max_in_flight`, `serial`, `serial_groups` at job level
