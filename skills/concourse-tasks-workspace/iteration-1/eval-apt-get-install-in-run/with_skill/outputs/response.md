# Fixing: `apt-get install` in `run.args`

## What's happening

Your task is hitting the classic `apt-get install` anti-pattern. Every run:

1. Pulls a bare `debian:bookworm-slim` image (no Node, no yarn)
2. Runs `apt-get update` (~15–30s)
3. Installs `nodejs` + `npm` from Debian mirrors (~45–60s, flaky on mirror outages)
4. `npm install -g yarn` (~15s)

That's 75–105s of setup before your code runs — and it floats the package versions, so your "reproducible" test run isn't actually reproducible.

## Recommended fix: pre-bake the image

Move the toolchain install into a Docker image that you build once and reuse forever. Your task shrinks to just the work.

### Step 1 — Dockerfile for your CI image

```dockerfile
# ci/images/unit-runner/Dockerfile
FROM node:20-bookworm-slim

# Install yarn via corepack (ships with Node 20 — no npm install -g needed)
RUN corepack enable && corepack prepare yarn@stable --activate

# Verify
RUN node --version && yarn --version
```

> **Why `node:20-bookworm-slim` instead of `debian:bookworm-slim`?**
> The official `node` image already has Node.js compiled and installed. Using it avoids the Debian package manager entirely.

### Step 2 — Build and push the image (one-time pipeline job)

```yaml
# pipeline.yml (add this job)
resources:
  - name: ci-image-src
    type: git
    source:
      uri: https://github.com/your-org/your-repo.git
      paths:
        - ci/images/unit-runner/   # only triggers when the Dockerfile changes

  - name: unit-runner-image
    type: registry-image
    source:
      repository: ghcr.io/your-org/unit-runner
      username: ((ghcr-user))
      password: ((ghcr-token))

jobs:
  - name: build-unit-runner
    plan:
      - get: ci-image-src
        trigger: true
      - task: build
        privileged: true
        config:
          platform: linux
          image_resource:
            type: registry-image
            source:
              repository: concourse/oci-build-task
          inputs:
            - name: ci-image-src
          outputs:
            - name: image
          caches:
            - path: cache    # buildkit layer cache — huge speedup on same worker
          run:
            path: build
          params:
            CONTEXT: ci-image-src/ci/images/unit-runner
            DOCKERFILE: ci-image-src/ci/images/unit-runner/Dockerfile
      - put: unit-runner-image
        params:
          image: image/image.tar
```

### Step 3 — Updated `unit` task

```yaml
# ci/tasks/unit.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: ghcr.io/your-org/unit-runner
    tag: latest
  version:
    digest: "sha256:<pin-after-first-push>"  # replace with actual digest after first build

inputs:
  - name: source

outputs:
  - name: junit

caches:
  - path: source/node_modules   # worker-local yarn install cache

run:
  path: bash
  args:
    - -ec
    - |
      cd source
      yarn install
      yarn test --reporter junit --output-file ../junit/results.xml
```

## What this gets you

| Step | Before | After |
|---|---|---|
| `apt-get update` + install | ~75–105s | 0s (baked in) |
| `yarn install` (warm cache) | ~15s | ~2–5s |
| Test suite | ~30s | ~30s |
| **Total** | **~2min+** | **~35s** |

At 50 runs/day, you're saving roughly **75–90 minutes of wall-clock CI time per day**.

## Two notes on the `caches:` line

The `caches:` block keeps `node_modules` on the worker between runs of the same job. When the same worker handles consecutive runs, `yarn install` becomes a near-no-op.

**Caveat:** Concourse `caches:` are worker-local. If your job runs on different workers (common in autoscaling setups), the cache will be cold. For cross-worker dependency caching, see the cache-as-task pattern (serialize `node_modules` to a tarball output, store via an S3 resource). For most teams, worker-local cache is sufficient and simpler.

## If you can't push a custom image right now

As a quick interim fix (not recommended long-term), switch from `debian:bookworm-slim` to `node:20-bookworm-slim` and remove the `apt-get` lines:

```yaml
# ci/tasks/unit.yml  (interim — still not pinned, but removes apt-get)
platform: linux

image_resource:
  type: registry-image
  source:
    repository: node
    tag: "20-bookworm-slim"

inputs:
  - name: source

outputs:
  - name: junit

caches:
  - path: source/node_modules

run:
  path: bash
  args:
    - -ec
    - |
      corepack enable
      cd source
      yarn install
      yarn test --reporter junit --output-file ../junit/results.xml
```

This alone saves ~75–90s per run (eliminates the `apt-get` block) while you work on the pre-baked image.

## Pinning the image digest

After your first successful image push, get the digest:

```bash
# From fly or skopeo:
skopeo inspect docker://ghcr.io/your-org/unit-runner:latest | jq .Digest
```

Then set `version.digest` in the task's `image_resource`. This makes every run byte-for-byte reproducible and lets you use `fly execute` locally with the exact same image.
