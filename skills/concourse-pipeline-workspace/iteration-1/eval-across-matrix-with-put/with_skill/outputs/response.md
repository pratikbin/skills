# Fix: `across` matrix with S3 artifact publish

## What's wrong with your current pipeline

Your pipeline has two problems that both stem from the same `across` constraint:

1. **`get` inside `across` is not supported.** Resource names are never var-interpolated inside `across`. Concourse will silently ignore the step or error. `get` steps must live *outside* the `across` block.

2. **`put` inside `across` referencing a static resource name works syntactically, but the artifact path uses build-step outputs that don't escape `across`.** More importantly, your task writes reports to `source/reports/…` — but `source` is fetched inside the matrix, so each combination would re-fetch it on every iteration (slow, and broken because `get` isn't allowed there anyway).

3. **Outputs produced inside `across` do not propagate to the outer plan.** You can't collect all 6 report tarballs after the `across` block finishes. You must `put` each one to S3 *inside* the `across` body, individually.

## The correct structure

- Fetch `source` **once**, before `across`.
- Run `task` inside `across` — one per combination.
- `put` to S3 **inside** the `across` body, immediately after the task that generates the report. Each combination publishes its own artifact.
- Use `max_in_flight: all` to run all 6 combinations in parallel.

## Working pipeline

```yaml
resources:
  - name: source
    type: git
    source:
      uri: https://github.com/your-org/your-repo.git

  - name: test-reports
    type: s3
    source:
      bucket: your-bucket
      region_name: us-east-1
      access_key_id: ((s3_access_key))
      secret_access_key: ((s3_secret_key))
      # versioned_file is set per-put via `file:` in params

jobs:
  - name: matrix-test
    plan:
      # Fetch source ONCE, outside across. get/put are not allowed inside across.
      - get: source
        trigger: true

      # across runs one body per combination: 3 go versions × 2 OSes = 6 parallel runs
      - across:
          - var: go_v
            values: ["1.22", "1.23", "1.24"]
          - var: os
            values: ["linux", "darwin"]
        max_in_flight: all   # run all 6 combinations simultaneously if workers are available
        fail_fast: true      # cancel remaining combinations on first failure
        do:
          # Task generates the report at: reports/((.:os))-((.:go_v)).tgz
          - task: test
            file: source/ci/test.yml
            vars:
              go: ((.:go_v))
              os: ((.:os))

          # put lives INSIDE across because outputs don't escape to the outer plan.
          # Each combination publishes its own artifact immediately after its task.
          - put: test-reports
            params:
              file: reports/((.:os))-((.:go_v)).tgz
            no_get: true   # skip the implicit re-fetch after put — saves time
```

## Key points

**Why `get` before `across`:** The `get` step fetches the versioned `source` artifact into a local directory called `source/`. All 6 `across` combinations share this already-fetched directory — no re-fetching per combination.

**Why `put` inside `across`:** Outputs from task steps inside `across` (like the `reports/` directory) are scoped to each combination's build container. They do not exist in the outer plan once `across` finishes. The only way to persist them is to `put` them to an external store (S3 here) inside the body, before the combination exits.

**Why `no_get: true` on the put:** After every `put`, Concourse by default does an implicit `get` to fetch the resource version it just pushed. For S3 file uploads you don't need the file back, so `no_get: true` skips that round-trip and saves time on every combination.

**`max_in_flight: all`:** All 6 combinations are dispatched simultaneously. If you have fewer than 6 workers, Concourse queues the remainder. If your cluster is small (e.g. 2 workers), use `max_in_flight: 2` to avoid starvation.

## Your task file must output to `reports/`

Make sure `source/ci/test.yml` declares an output named `reports`:

```yaml
# source/ci/test.yml
platform: linux   # or: ((os)) if you support darwin workers
image_resource:
  type: registry-image
  source:
    repository: golang
    tag: ((go))

inputs:
  - name: source

outputs:
  - name: reports

run:
  path: bash
  args:
    - -c
    - |
      cd source
      go test ./... 2>&1 | tee ../reports/test.log
      tar -czf ../reports/((os))-((go)).tgz ../reports/test.log
```

Note: `((os))` and `((go))` in the task file are resolved by the `vars:` you pass from the pipeline — they are static substitutions, not local var interpolations, so no `.:` prefix is needed inside the task file itself. The `.:` prefix is only for local vars *within the pipeline plan*.

## Summary of changes from your original

| Issue | Your version | Fixed version |
|---|---|---|
| `get` inside `across` | `- get: source` inside `do:` | Moved above `across` |
| `put` placement | Inside `across` ✓ | Inside `across` ✓ (was correct intent, wrong position due to `get` also being there) |
| `max_in_flight` | Missing | Added `max_in_flight: all` |
| `fail_fast` | Missing | Added `fail_fast: true` |
| Implicit re-fetch | Default (on) | `no_get: true` added |
