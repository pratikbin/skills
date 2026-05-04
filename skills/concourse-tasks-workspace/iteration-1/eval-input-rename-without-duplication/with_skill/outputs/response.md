# Keeping One `task.yml` with `input_mapping`

The feature you're thinking of is **`input_mapping`**. It lives on the `task` step in your pipeline YAML — not inside `task.yml` — and tells Concourse "when this task asks for `<task-side-name>`, hand it `<pipeline-side-name>` instead."

## The single, shared `task.yml`

```yaml
# ci/tasks/integration.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: your-test-runner-image
    tag: latest

inputs:
  - name: app-binary       # canonical name the script always sees

run:
  path: bash
  args:
    - -ec
    - |
      ./app-binary/run-integration-suite
```

This file never changes regardless of which service's binary is under test.

## Pipeline-side `task` step for the `orders` job

```yaml
jobs:
  - name: test-orders-api
    plan:
      - get: orders-api-bin        # fetched from whatever resource produces it
      - task: integration-test
        file: ci/tasks/integration.yml
        input_mapping:
          app-binary: orders-api-bin   # left = task.yml name, right = pipeline resource name
```

The `input_mapping` key is a map of `{ task-yml-name: pipeline-name }`. Concourse mounts the `orders-api-bin` artifact directory at the path the task expects (`app-binary/`). Your script sees `app-binary/` every time — it doesn't know or care which service binary it received.

## All three jobs, showing the pattern

```yaml
jobs:
  - name: test-orders-api
    plan:
      - get: orders-api-bin
      - task: integration-test
        file: ci/tasks/integration.yml
        input_mapping:
          app-binary: orders-api-bin

  - name: test-payments-api
    plan:
      - get: payments-api-bin
      - task: integration-test
        file: ci/tasks/integration.yml
        input_mapping:
          app-binary: payments-api-bin

  - name: test-users-api
    plan:
      - get: users-api-bin
      - task: integration-test
        file: ci/tasks/integration.yml
        input_mapping:
          app-binary: users-api-bin
```

Three jobs, one `task.yml`, three `input_mapping` declarations — each pointing at a different resource.

## Can you delete the duplicate task YAMLs?

Yes. The only thing that differed between them was the input name, and `input_mapping` replaces that entirely at the call site. Delete `ci/tasks/integration-orders.yml`, `ci/tasks/integration-payments.yml`, and `ci/tasks/integration-users.yml` (or however they were named). Keep only `ci/tasks/integration.yml`.

## Key rule to remember

`input_mapping` syntax is always:

```
task-yml-name: pipeline-resource-or-output-name
```

Left side is what `task.yml` declares under `inputs:`. Right side is what your job plan has available (a `get` step result, a previous task's `output_mapping` result, etc.). If you ever need the reverse — renaming a task *output* so downstream steps see a different name — use `output_mapping` with the same left=task/right=pipeline convention.
