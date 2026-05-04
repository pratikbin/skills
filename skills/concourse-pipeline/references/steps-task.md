# steps-task.md — task step schema

`task` runs a container-isolated unit of work. It's the only step that executes arbitrary code. Config lives either inline or in a referenced file.

## Schema

```yaml
- task: my-task-name           # required; display name for the step in the UI
  file: source/ci/task.yml     # path to a task config file (get the resource first)
  # OR inline config:
  config:
    platform: linux
    image_resource: {}         # see concourse-tasks skill
    inputs: []
    outputs: []
    caches: []
    run: {}
    params: {}
  # step-level overrides (apply regardless of file vs config):
  image: image-resource-name   # optional; override the task's image_resource with a fetched image artifact
  params: {}                   # optional; env vars injected into the task container (merged/overrides config params)
  vars: {}                     # optional; pipeline var interpolation inside the task config (not env vars)
  input_mapping: {}            # optional; rename input artifacts from plan space → task config names
  output_mapping: {}           # optional; rename output artifacts from task config names → plan space
  privileged: false            # optional; run container as root with extended capabilities (use sparingly)
```

### `file` vs `config`

Prefer `file`. It keeps task config versioned with the code it tests, allows the task to be run locally with `fly execute`, and avoids bloating the pipeline YAML. Use inline `config` only for very short glue steps or when the task is pipeline-specific and would never be reused.

### `params` vs `vars`

- `params`: key-value pairs injected as **environment variables** into the container process. The task sees them as `$MY_VAR`.
- `vars`: pipeline variables used for **YAML interpolation within the task config file itself** (e.g. `((go_version))` in `task.yml`). Not visible as env vars.

```yaml
- task: build
  file: source/ci/build.yml
  vars:
    go_version: "1.23"         # replaces ((go_version)) in build.yml at parse time
  params:
    CGO_ENABLED: "0"           # available as $CGO_ENABLED inside the container
```

### `input_mapping`

Maps artifact names from the plan into the names the task config expects. The task config declares `inputs: [{name: app-source}]`; the plan has an artifact called `source`. Without `input_mapping`, the task would fail because it can't find `app-source`.

```yaml
- task: check-params
  file: ci/tasks/check-distribution-env/task.yml
  image: unit-image
  input_mapping:
    distribution: concourse-chart    # task expects "distribution"; plan has "concourse-chart"
```

No need to rename the artifact in the plan or rewrite the task file. From `concourse/ci` k8s-check-helm-params job.

### `output_mapping`

Renames outputs from task config names to plan names, allowing downstream steps to reference them with a different name.

```yaml
- task: compile
  file: ci/tasks/compile.yml
  output_mapping:
    compiled-binary: app-binary     # task produces "compiled-binary"; rest of plan uses "app-binary"
- put: artifact-store
  params:
    file: app-binary/app-*.tar.gz
```

### `image`

Override the image declared in the task config file with an artifact fetched by a `get` step earlier in the plan. The `get` step produces an OCI image layout directory; `image:` points to that artifact name.

```yaml
- get: unit-image
- task: unit-tests
  file: ci/tasks/test.yml
  image: unit-image        # uses the fetched image instead of whatever task.yml declares
```

## Examples

### Inline config for a short glue step

```yaml
- task: extract-version
  config:
    platform: linux
    image_resource:
      type: registry-image
      source: { repository: alpine, tag: "3.19" }
    inputs:
      - name: release-notes
    outputs:
      - name: version-info
    run:
      path: sh
      args:
        - -c
        - "grep '^version:' release-notes/notes.md | cut -d' ' -f2 > version-info/version"
```

Short enough that a separate file adds no value. If this grows beyond ~10 lines of shell, move to a file.

### `input_mapping` to connect mismatched artifact names

Task file `ci/tasks/lint.yml` was written expecting an input named `repo`. The pipeline's git resource is named `source`. Rather than forking the task file or renaming the resource:

```yaml
- get: source
  trigger: true
- task: lint
  file: ci/tasks/lint.yml
  input_mapping:
    repo: source           # task sees "repo"; pipeline calls it "source"
```

### `privileged: true` for OCI image builds

```yaml
- task: build-image
  privileged: true         # oci-build-task requires root for overlay mounts
  file: ci/tasks/build-image.yml
  image: oci-build-task
  params:
    CONTEXT: source
    DOCKERFILE: source/Dockerfile
```

Only use `privileged: true` when the task genuinely requires it (container-in-container builds, low-level network ops). It bypasses container isolation.

## Gotchas

- `params` at the task step level **merge with and override** params defined in the task config file. They do not replace them entirely. Use this to inject pipeline-specific secrets without modifying the task file.
- `file:` paths are relative to the working directory of the build, which is the parent directory of all input artifacts. So `source/ci/task.yml` works when `source` is a fetched `get` artifact.
- `vars:` is only useful if the task config file uses `((var))` interpolation syntax. If the task just reads env vars, use `params:` instead.
- `image:` on the step overrides `image_resource:` in the task config at runtime. It does not modify the file.
- Inline `config` does not support `vars:` interpolation at the `config:` block level in the same way `file:` does — use `params:` for env-var injection in inline tasks.

## See also

- `concourse-tasks` skill — full task config schema: `image_resource`, `inputs`, `outputs`, `caches`, `run`, `params`
- `references/steps-flow.md` — composing tasks with `in_parallel`, `across`, `do`, `try`
- `references/modifiers-hooks.md` — `timeout`, `attempts`, `on_failure` on task steps
