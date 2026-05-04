# oci-build-task.md

Concourse-blessed Buildkit task for building OCI/Docker images inside CI without Docker daemon or privileged containers.

Source: `concourse-oci-build::readme`

## What it is

`concourse/oci-build-task` is an official Concourse task image that wraps Buildkit. It produces a tarball (`image/image.tar`) consumed by `registry-image`'s `put`. No Docker socket required. Supports secrets, SSH, multi-platform builds, and layer caching.

## Task skeleton

```yaml
# ci/tasks/build-image.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: concourse/oci-build-task

inputs:
  - name: source

outputs:
  - name: image

caches:
  - path: cache            # buildkit layer cache — same worker = huge speedup

run:
  path: build              # entrypoint from the oci-build-task image
```

## Params reference

```yaml
params:
  # --- Required / most common ---
  CONTEXT: source                        # path to docker build context (input name or subdir)
  DOCKERFILE: source/Dockerfile          # default: $CONTEXT/Dockerfile

  # --- Build args ---
  BUILD_ARG_GO_VERSION: "1.22"           # becomes --build-arg GO_VERSION=1.22
  BUILD_ARG_APP_NAME: my-service

  # --- Targets ---
  TARGET: production                     # --target production

  # --- Multi-platform ---
  IMAGE_PLATFORM: linux/amd64,linux/arm64  # comma-separated platforms
  OUTPUT_OCI: "true"                     # required for multi-arch; output is OCI layout dir

  # --- Using another image as a build arg ---
  IMAGE_ARG_BASE_IMAGE: base-image/image.tar  # becomes --build-arg BASE_IMAGE=<image>
  # requires input named "base-image"

  # --- Secrets ---
  BUILDKIT_SECRET_npmrc: .npmrc           # --secret id=npmrc,src=.npmrc
  # requires input with .npmrc file

  # --- SSH ---
  BUILDKIT_SSH: default                   # --ssh default; mount default SSH agent

  # --- Registry mirror ---
  REGISTRY_MIRRORS: "registry-mirror.internal:5000"  # comma-separated

  # --- Advanced ---
  BUILDKIT_EXTRA_CONFIG: |               # raw buildkitd.toml additions
    [registry."docker.io"]
      mirrors = ["mirror.example.com"]
  UNPACK_ROOTFS: "true"                  # unpack image for use as task rootfs
  LABEL_*: "value"                       # adds OCI image labels
```

## Example 1 — simple build and push

```yaml
# pipeline.yml
resources:
  - name: source
    type: git
    source:
      uri: https://github.com/org/app.git

  - name: app-image
    type: registry-image
    source:
      repository: ghcr.io/org/app
      username: ((ghcr-user))
      password: ((ghcr-token))

jobs:
  - name: build-push
    plan:
      - get: source
        trigger: true
      - task: build
        privileged: true              # required for buildkit
        file: ci/tasks/build-image.yml
        params:
          CONTEXT: source
          DOCKERFILE: source/Dockerfile
      - put: app-image
        params:
          image: image/image.tar
```

```yaml
# ci/tasks/build-image.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: concourse/oci-build-task

inputs:
  - name: source

outputs:
  - name: image

caches:
  - path: cache

run:
  path: build

params:
  CONTEXT: source
  DOCKERFILE: source/Dockerfile
  BUILD_ARG_APP_VERSION: "1.0.0"
```

## Example 2 — multi-arch build

```yaml
# ci/tasks/build-multiarch.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: concourse/oci-build-task

inputs:
  - name: source

outputs:
  - name: image

caches:
  - path: cache

run:
  path: build

params:
  CONTEXT: source
  IMAGE_PLATFORM: linux/amd64,linux/arm64
  OUTPUT_OCI: "true"
```

Multi-arch output is OCI Image Layout format at `image/image`. Push with `registry-image` put using `format: oci`.

## Example 3 — build with secret (npm token)

```yaml
# ci/tasks/build-with-secret.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: concourse/oci-build-task

inputs:
  - name: source
  - name: npmrc           # contains .npmrc with NPM_TOKEN

outputs:
  - name: image

caches:
  - path: cache

run:
  path: build

params:
  CONTEXT: source
  BUILDKIT_SECRET_npmrc: npmrc/.npmrc    # --secret id=npmrc,src=npmrc/.npmrc
```

In the Dockerfile: `RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm install`

## Gotchas

- `privileged: true` is **required** on the task step in the pipeline. Buildkit needs it.
- `caches: [{path: cache}]` is nearly always worth adding. Omitting it means cold Buildkit layer cache every run.
- `OUTPUT_OCI: "true"` required for multi-arch pushes. Single-arch can use the default tarball format.
- `IMAGE_PLATFORM` without `OUTPUT_OCI: "true"` silently builds only the first platform.
- `BUILDKIT_SECRET_*` and `BUILDKIT_SSH` require the corresponding input to provide the file/socket.

## See also

- `image-resource.md` — consuming built images as task images
- `caches.md` — layer cache mechanics
- `pure-function-model.md` — why pre-baked images beat build-in-run
- `anti-patterns.md` — oci-build-task without cache; hand-rolled buildkit
