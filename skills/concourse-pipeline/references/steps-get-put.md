# steps-get-put.md — get and put step schema

`get` fetches a resource version into the build container filesystem. `put` pushes a new version to a resource and optionally fetches it back.

## get schema

```yaml
- get: local-name          # required; name of a declared resource (or alias via `resource:`)
  resource: real-name      # optional; actual resource name when local-name differs
  params: {}               # optional; arbitrary map passed to the resource's `in` script
  version: latest          # optional; latest (default) | every | {key: value} pinned version
  passed: []               # optional; list of job names — only fetch versions that survived these jobs
  trigger: false           # optional; when true, a new version automatically schedules this job
```

### `version`

| Value | Behaviour |
|---|---|
| `latest` (default) | fetch the most recent version available |
| `every` | walk through all unchecked versions one build at a time — job runs once per new version |
| `{ref: "abc123"}` | pin to a specific version; useful for reproducible builds |

`version: every` is rarely the right choice. With a fast-moving repo it queues a build per commit. Most pipelines want `latest` (just catch up to HEAD) or a pinned version for release stages.

## put schema

```yaml
- put: local-name          # required; name of a declared resource
  resource: real-name      # optional; actual resource name when alias needed
  params: {}               # required (resource-specific); passed to the resource's `out` script
  get_params: {}           # optional; params for the implicit get that follows the put
  no_get: false            # optional; when true, skip the implicit get entirely
  inputs: all              # optional; all (default) | detect | [explicit-list] — which artifacts to upload
```

### `no_get`

After every `put`, Concourse runs an implicit `get` to fetch the newly created version back into the build. This is almost always correct — you get the version metadata and artifact back. Skip it with `no_get: true` when:

- The artifact is large and the build doesn't need it downstream.
- You're doing a `put` to a notification resource (Slack, GitHub status) where there's nothing to fetch.

From `concourse/ci` container-dependencies pipeline:

```yaml
- in_parallel:
  - put: runc-amd64
    no_get: true
    params:
      file: runc-bin/runc.amd64
  - put: runc-arm64
    no_get: true
    params:
      file: runc-bin/runc.arm64
```

Both puts publish binary blobs. No downstream step needs them back; skip the implicit get.

## Examples

### Trigger get vs constraint-only get

```yaml
jobs:
  - name: integration
    plan:
      - in_parallel:
          - get: source
            trigger: true          # new commit → run this job
            passed: [unit]         # only versions that passed unit
          - get: test-image
            # no trigger: true     # image changes don't independently re-run integration
            passed: [build-image]  # but must still be from a built image
      - task: run-integration
        file: source/ci/integration.yml
        image: test-image
```

`source` triggers the job; `test-image` only constrains the version (must have passed `build-image`). Adding `trigger: true` to `test-image` would cause a double-run when both update simultaneously. See `references/passed-chains.md`.

### Pinned version for a reproducible release stage

```yaml
- get: release-candidate
  version: { ref: "v1.2.3-rc.1" }   # exact version; won't drift if newer RCs appear
  passed: [smoke-test]
```

### `get_params` to control the implicit fetch after put

```yaml
- put: app-image
  params:
    build: source
  get_params:
    skip_download: true     # don't pull the multi-GB image back after push
```

Equivalent to `no_get: true` for download-heavy resources. Prefer `no_get: true` for clarity unless you need the version metadata but not the artifact bytes.

### `resource:` alias for multiple gets of the same resource

```yaml
resources:
  - name: artifact
    type: s3
    source:
      bucket: my-bucket
      regexp: artifacts/build-(.*).tgz

jobs:
  - name: promote
    plan:
      - get: staging-artifact
        resource: artifact
        version: { path: "artifacts/build-1.2.3.tgz" }
        passed: [staging-smoke]
      - put: prod-artifact
        resource: artifact
        params: { file: staging-artifact/build-*.tgz }
```

Same underlying resource; two different local names for clarity.

## Gotchas

- `trigger: true` with no `passed:` means "run on every new version of this resource" — usually what you want for the entry point of a pipeline. Deep in a chain, omit `trigger: true` to avoid spurious runs.
- `version: every` combined with a fast resource (git with many commits) will create a build backlog that Concourse will work through one-by-one. Usually wrong unless you need to process every commit.
- `inputs:` on `put` defaults to `all`, which uploads every artifact from the build to the worker for the put step. With large artifacts, `inputs: detect` (let Concourse infer from params) or an explicit list saves time.
- `passed:` with an empty list (`passed: []`) is different from omitting `passed:` entirely. Empty list = no constraint. Omitted = no constraint. Same effect. Use omit for clarity.

## See also

- `references/passed-chains.md` — trigger vs constraint, fan-in, version skew
- `references/parallelism-patterns.md` — wrap multiple gets in `in_parallel`
- `concourse-resources` skill — resource-specific `params` and `get_params` options
