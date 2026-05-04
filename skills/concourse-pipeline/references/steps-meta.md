# steps-meta.md — load_var and set_pipeline

Meta steps that operate on the pipeline itself or on build-time variable discovery rather than external resources.

## `load_var` schema

Reads a file from an input artifact and loads its contents as a pipeline variable, available for the rest of the build via `((.:varname))`.

```yaml
- load_var: var-name           # required; the variable name to set (referenced as ((.:var-name)))
  file: artifact/path/to/file  # required; path to the file relative to build working directory
  format: raw                  # optional; raw (default) | yaml | json | env
  reveal: false                # optional; when true, logs the loaded value in the build output (default: false)
```

### `format`

| Format | Effect |
|---|---|
| `raw` | file content as a single string variable |
| `yaml` | parse file as YAML; sets nested keys as `((.:varname.key))` |
| `json` | parse file as JSON; same nested access |
| `env` | parse file as `KEY=VALUE` pairs; each key becomes `((.:KEY))` |

### `reveal`

By default, loaded var values are redacted in build logs (treated like credentials). Set `reveal: true` for non-sensitive values (e.g., version strings, tag names) to make the build output readable.

## `set_pipeline` schema

Creates or updates a pipeline within Concourse, using a YAML file from a fetched artifact. Core pipeline-as-code primitive.

```yaml
- set_pipeline: pipeline-name   # required; pipeline name, or "self" to update the current pipeline
  file: source/ci/pipeline.yml  # required; path to the pipeline YAML file
  var_files: []                 # optional; list of var file paths whose values are interpolated into the pipeline
  vars: {}                      # optional; inline key-value vars interpolated into the pipeline
  instance_vars: {}             # optional; instance vars for pipeline groups/instanced pipelines
  team: null                    # optional; target team name (default: current team)
```

### `set_pipeline: self`

Sets the current pipeline to update its own config. The pipeline reads its own source and applies changes. This is the self-updating pattern.

## Examples

### `load_var` for dynamic tag from a release

From `concourse/ci` container-dependencies pipeline:

```yaml
jobs:
  - name: runc
    plan:
      - in_parallel:
          - get: ci
          - get: runc-release
            trigger: true
            params:
              globs: [none]
          - get: oci-build-task
      - load_var: runc_tag
        reveal: true
        file: runc-release/tag
      - task: build-runc-binaries
        privileged: true
        image: oci-build-task
        file: ci/tasks/runc/task.yml
        params:
          RUNC_TAG: ((.:runc_tag))
```

The release resource puts a `tag` file in the artifact directory. `load_var` reads it; `reveal: true` lets the tag value appear in logs. The task receives it as `$RUNC_TAG`.

### `load_var` with JSON format for structured data

```yaml
- task: generate-manifest
  file: ci/tasks/manifest.yml
  # outputs a manifest.json like: {"version":"1.2.3","commit":"abc123","env":"prod"}
- load_var: manifest
  file: generated/manifest.json
  format: json
  reveal: true
- task: deploy
  file: ci/tasks/deploy.yml
  params:
    VERSION: ((.:manifest.version))
    COMMIT: ((.:manifest.commit))
    ENV: ((.:manifest.env))
```

### Self-updating pipeline

The pipeline fetches its own source and applies the updated config:

```yaml
resources:
  - name: ci
    type: git
    source:
      uri: https://github.com/myorg/ci
      branch: main

jobs:
  - name: reconfigure-self
    plan:
      - get: ci
        trigger: true
      - set_pipeline: self
        file: ci/pipelines/main.yml
        var_files:
          - ci/config/vars.yml
```

On every push to the `ci` repo, the pipeline updates itself. New jobs, modified resources, and changed config take effect automatically. From `concourse/ci` reconfigure pattern.

### `set_pipeline` to manage child pipelines

```yaml
jobs:
  - name: render-and-set-pipelines
    plan:
      - get: pipelines-source
        trigger: true
      - task: render-pipelines
        file: pipelines-source/ci/render.yml
      - set_pipeline: service-a
        file: rendered/service-a.yml
        var_files:
          - pipelines-source/config/prod.yml
        vars:
          team: platform
      - set_pipeline: service-b
        file: rendered/service-b.yml
        instance_vars:
          environment: prod
```

Multiple `set_pipeline` steps in sequence. Each runs serially; errors in one skip the rest unless wrapped in `try`.

## Gotchas

- `load_var` variables are **build-scoped only** — they exist for the duration of this build and are not stored anywhere. They are not accessible in other jobs or future builds.
- `((.:varname))` syntax (with the `.` prefix) is required to reference build-local vars from `load_var`. Without `.`, Concourse looks in credential managers.
- `set_pipeline: self` silently no-ops if the pipeline definition hasn't changed (Concourse diffs before applying). This means the step always succeeds even with a typo if the current config was already valid — validate separately with `fly validate-pipeline`.
- `team:` in `set_pipeline` requires the current team's pipeline to have `set_pipeline` permission on the target team. If omitted, defaults to current team.
- `var_files` paths must be available as fetched artifacts in the current build. They are loaded in order; later files override earlier values for the same key.
- Don't mix `set_pipeline` with tests in the same job if test failure should block pipeline update. Split into separate jobs: test → (passed) → set_pipeline.

## See also

- `references/steps-get-put.md` — fetching the source artifact before set_pipeline
- `references/passed-chains.md` — chaining reconfigure job after validation passes
- `concourse-ops` skill — instance pipelines, team permissions, fly validate-pipeline
