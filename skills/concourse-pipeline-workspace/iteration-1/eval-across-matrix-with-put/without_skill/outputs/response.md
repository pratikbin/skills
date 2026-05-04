# Fixing the Concourse `across` Matrix Pipeline

There are several issues in your pipeline. Here is a working version, followed by an explanation of each fix.

## Working Pipeline

```yaml
resources:
  - name: source
    type: git
    source:
      uri: https://github.com/your-org/your-repo

  - name: test-reports
    type: s3
    source:
      bucket: your-bucket
      region_name: us-east-1
      access_key_id: ((aws_access_key_id))
      secret_access_key: ((aws_secret_access_key))
      regexp: reports/.*\.tgz

jobs:
  - name: matrix-test
    plan:
      - get: source
        trigger: true
      - across:
          - var: go_v
            values: ["1.22", "1.23", "1.24"]
          - var: os
            values: ["linux", "darwin"]
        max_in_flight: all
        do:
          - task: test-((.:os))-((.:go_v))
            file: source/ci/test.yml
            vars:
              go: ((.:go_v))
              os: ((.:os))
          - put: test-reports
            params:
              file: reports/((.:os))-((.:go_v)).tgz
```

## What Was Wrong

### 1. `get` was inside `across` — move it out

The `get: source` step does not vary across matrix dimensions. Putting it inside `do:` means Concourse tries to trigger 6 separate get operations, each competing for the same resource version. This causes race conditions and often a "resource already fetched" error. Move `get: source` **before** the `across` block.

### 2. Missing `max_in_flight: all`

Without `max_in_flight`, Concourse serializes the `across` iterations by default. You said you want all 6 to run in parallel when workers are available. Set `max_in_flight: all` (or a specific number like `6`) on the `across` step.

### 3. Task names must be unique within a build

When `across` expands your matrix, each iteration runs a step named `test`. Concourse rejects duplicate step names in the same build plan. Give the task a name that includes the matrix variables: `test-((.:os))-((.:go_v))`. This makes each task name unique and also makes the build UI readable.

### 4. `put` artifact path

Your original had `source/reports/((.:os))-((.:go_v)).tgz`. The `source` prefix is the input directory name — that is correct for reading input files in a `task`, but the `put` step's `params.file` is a glob/path relative to the **working directory of the build** (i.e., the root where all input/output volumes are mounted). If your task writes the report to an output volume named `reports`, then the path should be `reports/((.:os))-((.:go_v)).tgz` — no `source/` prefix.

If your task writes reports back into the `source` volume, then `source/reports/((.:os))-((.:go_v)).tgz` is correct — just make sure your task declares `source` as an output (not just an input) so the artifact is visible to the `put` step.

### 5. S3 resource `regexp` vs `versioned_file`

For publishing multiple files (6 different names), use `regexp` in the S3 resource config, not `versioned_file`. The regexp should match all the filenames your matrix produces. The example above uses `reports/.*\.tgz` as a catch-all.

## Summary of Changes

| Issue | Original | Fixed |
|---|---|---|
| `get` placement | inside `across` | before `across` |
| Parallelism | not set (serialized) | `max_in_flight: all` |
| Task name | `test` (duplicated 6×) | `test-((.:os))-((.:go_v))` |
| Artifact path | verify output volume name | matches task output volume |
| S3 resource | not shown | use `regexp` for multi-file publish |
