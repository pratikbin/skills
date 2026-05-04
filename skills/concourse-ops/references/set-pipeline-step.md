# set_pipeline step

Reconfigure a pipeline from within a build. Enables self-updating pipelines and automated child pipeline management.

## Schema

```yaml
# Full schema
- set_pipeline: <pipeline-name>   # or "self" to reconfigure current pipeline
  file: path/to/pipeline.yml      # required; path within workspace
  var_files:                      # optional; list of var files to load
    - path/to/vars.yml
  vars:                           # optional; inline key=value overrides
    key: value
  team: other-team                # optional; set pipeline on a different team (must be member)
  instance_vars:                  # optional; makes this an instanced pipeline
    branch: main
```

`set_pipeline: self` is a special token meaning "the pipeline this build belongs to". The pipeline name does not need to be hard-coded.

## Examples

### Self-update pattern (canonical)

```yaml
resources:
  - name: ci
    type: git
    source:
      uri: https://github.com/myorg/ci.git
      branch: main

jobs:
  - name: reconfigure-self
    plan:
      - get: ci
        trigger: true
      - set_pipeline: self
        file: ci/pipelines/main.yml
        var_files:
          - ci/pipelines/vars.yml
```

Every push to the `ci` repo re-applies the pipeline. Drift between repo and live config is impossible.

### Child pipeline with instance vars

```yaml
jobs:
  - name: manage-branch-pipelines
    plan:
      - get: repo
        trigger: true
      - set_pipeline: feature-pipeline
        file: repo/ci/pipeline.yml
        instance_vars:
          branch: ((branch))
        vars:
          image_tag: ((.:branch))
```

Creates or updates an instanced pipeline `feature-pipeline/branch:main` (etc.).

### Cross-team set

```yaml
      - set_pipeline: ops-monitoring
        file: ci/monitoring.yml
        team: ops-team
```

The `web` process must be authenticated as a member of `ops-team`. The step's build team must have `member` role in the target team.

## Child pipeline ownership and archival

- A pipeline set by a `set_pipeline` step is "owned" by the parent pipeline's team.
- If the parent job stops calling `set_pipeline: <child>`, the child pipeline is **not** automatically removed.
- Operators or the owning job must call `fly archive-pipeline` or `fly destroy-pipeline` to clean up.
- Concourse does NOT auto-archive pipelines that were created by `set_pipeline` when the parent is destroyed.

## OPA hook

When `CONCOURSE_OPA_URL` is set, every `set_pipeline` call sends a policy check. The OPA input includes:

```json
{
  "action": "SetPipeline",
  "team": "my-team",
  "pipeline": "my-pipeline",
  "config": { ... }
}
```

OPA can deny the action or return warnings. See `references/opa.md`.

## Gotchas

- `set_pipeline: self` only works inside a pipeline build. One-off `fly execute` builds have no "self".
- `var_files` paths are relative to the workspace root (the build's task working directory), not the task container filesystem.
- `team:` requires the ATC to have credentials that can mutate the target team. Use with care in multi-tenant clusters.
- Setting `instance_vars:` on an existing non-instanced pipeline of the same name will error. Destroy the old one first.

## See also

- `references/instance-pipelines.md` — full instanced pipeline semantics
- `references/vars-and-var-sources.md` — `((var))` interpolation, `var_sources:`
- `references/opa.md` — policy enforcement on `set_pipeline`
- `references/fly-cli.md` — `fly set-pipeline` flags
