# inputs-outputs.md

How Concourse mounts directories into task containers and extracts artifacts after exit.

## Schema

```yaml
inputs:
  - name: source            # required. must match a resource/output name in the job
    path: source            # optional. default = name. relative path inside container
    optional: false         # optional. default false. if true, task runs even if input absent

outputs:
  - name: compiled          # required
    path: compiled          # optional. default = name
```

Concourse creates a working directory per build. Each input/output is a subdirectory of `/tmp/build/<id>/`. Absolute paths are not allowed in `path`.

Inputs are mounted read-only by convention (the task can write, but changes aren't tracked). Outputs are the mechanism for passing artifacts to subsequent steps.

## `input_mapping` and `output_mapping` at the step

Defined on the **task step** in the pipeline, not in `task.yml`. Let you rename without touching the shared task config file.

```yaml
# task.yml expects: inputs: [{name: app}, {name: config}]
# task.yml expects: outputs: [{name: report}]

- task: lint
  file: ci/tasks/lint.yml
  input_mapping:
    app: orders-api-source    # "orders-api-source" resource → mounted as "app"
    config: shared-lint-cfg   # "shared-lint-cfg" resource → mounted as "config"
  output_mapping:
    report: lint-report-out   # task output "report" → available downstream as "lint-report-out"
```

`input_mapping: {task-name: pipeline-name}` — left is what task.yml calls it, right is what the pipeline has.

`output_mapping: {task-name: pipeline-name}` — left is task output, right is name downstream steps use.

## Example 1 — two upstreams, one task

Two jobs produce artifacts named differently. One shared `package.yml` task expects `app-binary` and `config`. Use `input_mapping` to wire them up:

```yaml
resources:
  - name: orders-api-bin   # produced by build job
    type: s3
    source: { bucket: ci-artifacts, regexp: orders-api-(.*).tar.gz }
  - name: deploy-config
    type: git
    source: { uri: git@github.com:org/deploy-config }

jobs:
  - name: integration-test
    plan:
      - get: orders-api-bin
      - get: deploy-config
      - task: run-integration
        file: ci/tasks/integration.yml
        input_mapping:
          app-binary: orders-api-bin  # task.yml names it "app-binary"
          config: deploy-config        # task.yml names it "config"
```

`ci/tasks/integration.yml` never needs to change when upstream resource names change.

## Example 2 — optional input for matrix builds

```yaml
# task.yml
inputs:
  - name: source
  - name: extra-fixtures
    optional: true
run:
  path: ci/tasks/test/run.sh
```

```yaml
# pipeline.yml job A — has fixtures
- task: test
  file: ci/tasks/test.yml
  input_mapping:
    extra-fixtures: integration-fixtures

# pipeline.yml job B — no fixtures, task still runs
- task: test
  file: ci/tasks/test.yml
  # extra-fixtures not provided; optional: true allows this
```

The task script must handle both cases: check if `extra-fixtures/` is empty and branch accordingly.

## Gotchas

- Declaring an input that no upstream step provides → build fails (unless `optional: true`).
- `path` is relative and must not start with `/` or contain `../`.
- `output_mapping` does not rename the directory on disk — it only changes what downstream steps see in the build plan.
- If two tasks share a `task.yml` file in the same job, give them different step names; output names must be unique per job plan.
- Outputs are empty directories at task start. Task is responsible for writing to them.

## See also

- `schema.md` — full inputs/outputs field spec
- `caches.md` — similar mount concept, but persisted across runs
- `anti-patterns.md` — missing outputs declaration
