# image-resource.md

Specifies the container image a task runs in. Fetched by the worker immediately before task execution.

## Schema

```yaml
image_resource:
  type: registry-image       # almost always. other types are exotic.
  source:
    repository: golang        # required. image name (no tag here)
    tag: "1.22.3"             # optional. default: latest (bad — see gotchas)
    # Private registry auth:
    username: ((registry-user))
    password: ((registry-pass))
    # Non-docker.io registry:
    # repository: ghcr.io/org/image
  version:
    digest: "sha256:abc123..."  # optional. pin to exact digest
```

## Pinning strategies

### Tag only — least reproducible

```yaml
image_resource:
  type: registry-image
  source:
    repository: golang
    tag: "1.22"
```

Tag `1.22` is mutable. Registry may push a new image under the same tag. Breaks between runs.

### Tag + digest in `version:` — most reproducible

```yaml
image_resource:
  type: registry-image
  source:
    repository: golang
    tag: "1.22.3"
  version:
    digest: "sha256:aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111"
```

Concourse fetches the exact digest. Tag is informational. Update: change digest in task.yml.

### Digest-pinned pipeline resource (preferred for shared images)

Declare a `registry-image` resource at pipeline level, pin it, then reference via `image:` override on the task step:

```yaml
# pipeline.yml
resources:
  - name: golang-image
    type: registry-image
    check_every: 24h
    source:
      repository: golang
      tag: "1.22.3"

jobs:
  - name: build
    plan:
      - get: golang-image
        params: { format: oci }
      - get: source
      - task: compile
        image: golang-image    # overrides image_resource in task.yml
        file: ci/tasks/compile.yml
```

`image: golang-image` at the step level takes a previously `get`-fetched `registry-image` resource and uses it as the task's rootfs. The `image_resource:` in `compile.yml` is ignored when `image:` is set on the step.

## Custom builder images

Worth building when:
- Multiple tasks need the same toolchain (Go + protoc + jq + custom scripts).
- Tools require version pinning (protoc 25.x, specific Node, etc.).
- `apt-get install` in `run:` is adding > 30 s per task.

Not worth building when: single task, standard distro image already has the tool.

## Private registries

```yaml
image_resource:
  type: registry-image
  source:
    repository: registry.internal.example.com/ci/builder
    tag: "2.1"
    username: ((internal-registry-user))
    password: ((internal-registry-pass))
```

`((…))` values are resolved via the configured credential manager at pipeline load or task start — never hardcode creds.

## `image:` override on the task step

```yaml
# pipeline.yml — use a fetched resource as task image
- get: my-builder-image
- task: run-tests
  image: my-builder-image
  file: ci/tasks/test.yml
```

`my-builder-image` must be a `registry-image` resource fetched with `format: oci` (for unpacking) or the default rootfs format. Concourse uses it as the container rootfs. The `image_resource:` declared inside `test.yml` is bypassed entirely.

## Gotchas

- `tag: latest` is mutable and breaks reproducibility. Always pin.
- `image_resource:` is fetched by the worker per-build. Use pipeline-level resources + `image:` override to share a single fetch across steps.
- Digest changes when the image is rebuilt, even if the tag is the same.
- `type: docker-image` is the legacy type. Use `registry-image` for all new tasks.
- For GCR / ECR, `username` is often `oauth2accesstoken` / `AWS` and `password` is the token.

## See also

- `schema.md` — full `image_resource` placement in task config
- `pure-function-model.md` — why pinned images improve debuggability
- `oci-build-task.md` — building images in Concourse
- `anti-patterns.md` — `tag: latest` anti-pattern
