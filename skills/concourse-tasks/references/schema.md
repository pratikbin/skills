# schema.md

Full task config schema for Concourse v8+. Every field a `task.yml` can declare.

## Schema

```yaml
# task.yml — annotated full schema
platform: linux          # required. "linux" | "windows" | "darwin"

# rootfs_uri: direct OCI image reference (rarely used; prefer image_resource)
rootfs_uri: ""           # optional. mutually exclusive with image_resource

image_resource:          # optional when rootfs_uri set; required otherwise
  type: registry-image   # almost always registry-image
  source:
    repository: alpine
    tag: "3.19"
    # For private registries:
    # username: ((registry-user))
    # password: ((registry-pass))
  # Pin to exact digest — recommended for reproducibility
  version:
    digest: "sha256:abc123..."

params:                  # optional. env vars injected at task start (string values only)
  GO_VERSION: "1.22"
  SOME_FLAG: "true"

inputs:                  # optional list. directories mounted into container
  - name: source         # required. name matches upstream put/get resource or prior task output
    path: source         # optional. defaults to name. relative to /tmp/build/XXXX/
    optional: false      # optional. default false. if true, missing input is ok

outputs:                 # optional list. directories Concourse preserves for downstream steps
  - name: bin
    path: bin            # optional. defaults to name

caches:                  # optional. persisted across runs on same worker
  - path: node_modules   # relative to task working dir

container_limits:        # optional. enforce resource caps
  cpu: 512               # millicores (1000 = 1 vCPU). 0 = no limit
  memory: 1073741824     # bytes. also accepts "512m", "1g". 0 = no limit

run:                     # required
  path: bash             # required. executable; searched in $PATH or absolute
  args:                  # optional
    - -ec
    - |
      go build -o bin/app ./cmd/app
  dir: source            # optional. working directory inside container (relative)
  user: nobody           # optional. run as this user (overrides image USER)
```

## Minimal valid task.yml

```yaml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: busybox

run:
  path: echo
  args: ["hello world"]
```

## call-site: `file:` vs inline `config:`

At the pipeline step level, a task is referenced one of two ways:

```yaml
# file reference — task lives in a repo (preferred)
- task: build
  file: ci/tasks/build.yml

# inline — config embedded in pipeline YAML (avoid for reusable tasks)
- task: build
  config:
    platform: linux
    image_resource:
      type: registry-image
      source:
        repository: golang
        tag: "1.22"
    run:
      path: go
      args: [build, ./...]
```

`file:` keeps task portable, testable with `fly execute`, and version-controlled.
`config:` is fine for one-off pipeline-internal tasks but can't be referenced externally.

## Gotchas

- `params` values are always strings. Booleans/integers must be quoted: `"true"`, `"1"`.
- `inputs[].path` is relative — no leading `/`. Concourse prefixes `/tmp/build/<id>/`.
- `outputs` directories are created empty by Concourse; task must populate them.
- `container_limits.memory: 0` means unlimited, not zero bytes.
- `rootfs_uri` and `image_resource` are mutually exclusive; Concourse errors if both present.
- Missing `outputs:` declaration — downstream step gets an empty dir, not an error.

## See also

- `inputs-outputs.md` — input/output path mapping, input_mapping at call site
- `image-resource.md` — pinning, private registries, image: override
- `params-vs-vars.md` — when params leak secrets
- `run-block.md` — run.path vs embedded script details
