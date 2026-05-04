# anti-patterns.md

Common task config mistakes. Each entry: what's wrong, what to do instead.

---

## 1. `apt-get install` in `run.args`

```yaml
# WRONG
run:
  path: bash
  args:
    - -ec
    - |
      apt-get update -q && apt-get install -y curl jq
      jq .version source/manifest.json
```

Problems: slow (30-90 s per build), flaky (mirror outage), non-reproducible (package version floats).

```yaml
# RIGHT — bake tools into image
image_resource:
  type: registry-image
  source:
    repository: ghcr.io/org/ci-tools   # pre-installed: curl, jq
    tag: "1.3"
  version:
    digest: "sha256:abc123..."

run:
  path: bash
  args:
    - -ec
    - jq .version source/manifest.json
```

---

## 2. `tag: latest` on `image_resource`

```yaml
# WRONG
image_resource:
  type: registry-image
  source:
    repository: golang
    tag: latest             # mutable, breaks reproducibility
```

```yaml
# RIGHT
image_resource:
  type: registry-image
  source:
    repository: golang
    tag: "1.22.3"
  version:
    digest: "sha256:aaaaaa..."
```

---

## 3. Missing `outputs:` declaration

```yaml
# WRONG — task writes to bin/ but doesn't declare it
outputs: []

run:
  path: bash
  args:
    - -ec
    - go build -o bin/app ./cmd/app   # writes to bin/, but downstream can't see it
```

```yaml
# RIGHT
outputs:
  - name: bin

run:
  path: bash
  args:
    - -ec
    - go build -o bin/app ./cmd/app
```

Undeclared outputs are not exposed to downstream steps. The directory exists in the container but Concourse doesn't preserve it.

---

## 4. Cache path with build-ID suffix

```yaml
# WRONG — unique path per build = always a miss
caches:
  - path: node_modules_${BUILD_ID}

# Also wrong — dynamic path constructed in script
run:
  path: bash
  args:
    - -ec
    - CACHE_DIR="cache_$(date +%s)" && npm ci --cache $CACHE_DIR
```

```yaml
# RIGHT — stable path, Concourse owns the cache key
caches:
  - path: source/node_modules
```

---

## 5. Relying on `caches:` in `fly execute`

```yaml
# This silently does nothing in fly execute one-off builds
caches:
  - path: .gradle/caches
```

`fly execute` has no pipeline/job/step identity → no cache bucket → cache declarations ignored. If your task behaves differently with a warm cache, test it in a real pipeline job.

---

## 6. Secrets in `params:`

```yaml
# WRONG — visible in fly get-pipeline output
- task: push
  file: ci/tasks/push.yml
  params:
    REGISTRY_TOKEN: my-real-token    # plaintext in pipeline YAML
```

```yaml
# RIGHT — credential manager, never stored in pipeline config
- task: push
  file: ci/tasks/push.yml
  params:
    REGISTRY_TOKEN: ((registry-token))   # resolved at runtime, redacted in logs
```

---

## 7. Inline `config:` when the task is reused

```yaml
# WRONG — duplicated config in every job that uses this task
- task: lint
  config:
    platform: linux
    image_resource:
      type: registry-image
      source: { repository: golangci/golangci-lint, tag: "v1.55" }
    run:
      path: golangci-lint
      args: [run, ./...]
```

```yaml
# RIGHT — single source of truth in repo
- task: lint
  file: ci/tasks/lint.yml
```

Inline `config:` is fine for one-off pipeline-internal tasks. Not fine when the same config appears in multiple jobs.

---

## 8. `oci-build-task` without cache

```yaml
# WRONG — cold buildkit cache every run
# ci/tasks/build-image.yml
run:
  path: build
# no caches block
```

```yaml
# RIGHT — layer cache persists on the worker
caches:
  - path: cache

run:
  path: build
```

Warm buildkit cache can cut image build time by 80% on cache hits. Always add it.

---

## 9. `privileged: true` unnecessarily

```yaml
# WRONG — privileged on a plain Go build task
- task: compile
  file: ci/tasks/compile.yml
  privileged: true        # not needed; not building images
```

```yaml
# RIGHT — privileged only when actually building images with oci-build-task
- task: build-image
  file: ci/tasks/build-image.yml
  privileged: true        # required for buildkit
```

Privileged containers can escape the worker in misconfigured environments. Use only when Buildkit or equivalent requires it.

---

## 10. Hand-rolled buildkit instead of `oci-build-task`

```yaml
# WRONG — DIY buildkit plumbing
run:
  path: bash
  args:
    - -ec
    - |
      dockerd &
      sleep 3
      docker build -t image:latest .
      docker save image:latest > image.tar
```

```yaml
# RIGHT — use oci-build-task which handles buildkit setup correctly
image_resource:
  type: registry-image
  source:
    repository: concourse/oci-build-task

run:
  path: build
```

Hand-rolled Docker-in-Docker is fragile (race conditions, storage drivers, worker compatibility). `oci-build-task` handles all of it.

---

## 11. No `-e` flag in inline bash

```yaml
# WRONG — failures silently ignored
run:
  path: bash
  args:
    - -c
    - |
      go test ./...    # fails? doesn't matter, bash continues
      go build ./...   # runs even after test failure
```

```yaml
# RIGHT
run:
  path: bash
  args:
    - -ec              # -e exits on error
    - |
      go test ./...
      go build ./...
```

---

## See also

- `pure-function-model.md` — why pre-baked images beat runtime installs
- `image-resource.md` — pinning by digest
- `params-vs-vars.md` — secrets in params vs credential manager
- `caches.md` — correct cache path usage
- `oci-build-task.md` — correct image build setup
