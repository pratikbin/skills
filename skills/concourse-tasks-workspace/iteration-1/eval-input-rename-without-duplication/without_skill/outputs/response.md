# Concourse: One Task Config, Multiple Input Names via `input_mapping`

The feature you're thinking of is **`input_mapping`** on the `task` step. It tells Concourse "when the task config declares an input named X, satisfy it with resource Y from the pipeline."

---

## The Single Shared Task Config

`ci/tasks/integration.yml` — unchanged, always refers to `app-binary`:

```yaml
---
platform: linux

image_resource:
  type: registry-image
  source:
    repository: alpine
    tag: latest

inputs:
  - name: app-binary   # canonical name the task knows about

run:
  path: sh
  args:
    - -exc
    - |
      ls app-binary/
      app-binary/run-integration-tests
```

This file is the **single source of truth**. You can delete the two duplicates entirely.

---

## Pipeline-Side: `task` Step with `input_mapping`

For the `orders` job, the binary resource is named `orders-api-bin` in the pipeline. Use `input_mapping` to bridge the names:

```yaml
jobs:
  - name: integration-orders
    plan:
      - get: orders-api-bin          # fetches the resource
      - task: run-integration-tests
          file: ci/tasks/integration.yml
          input_mapping:
            app-binary: orders-api-bin   # task's name: pipeline resource name
```

For the other two jobs it's the same pattern, just different resource names:

```yaml
  - name: integration-payments
    plan:
      - get: payments-api-bin
      - task: run-integration-tests
        file: ci/tasks/integration.yml
        input_mapping:
          app-binary: payments-api-bin

  - name: integration-users
    plan:
      - get: users-api-bin
      - task: run-integration-tests
        file: ci/tasks/integration.yml
        input_mapping:
          app-binary: users-api-bin
```

---

## How `input_mapping` Works

`input_mapping` is a map of:

```
<task-config input name>: <name of artifact available in the build plan>
```

Concourse resolves task inputs at runtime. Without a mapping, it looks for an artifact whose name exactly matches the input name declared in the task config. With a mapping, you override that lookup — the task still sees a directory called `app-binary/`, but Concourse populated it from whatever the right-hand side names.

---

## Can You Delete the Duplicate Task YMLs?

**Yes, unconditionally.** The only reason to have separate task YMLs was the different `inputs[].name`. `input_mapping` eliminates that reason entirely. Keep one file, wire it three ways in the pipeline.

---

## Summary

| Before | After |
|--------|-------|
| `ci/tasks/integration-orders.yml` | deleted |
| `ci/tasks/integration-payments.yml` | deleted |
| `ci/tasks/integration-users.yml` → rename to `ci/tasks/integration.yml` | single shared file |
| 3 task steps, no mapping | 3 task steps, each with `input_mapping` |
