# Speeding Up oci-build-task in Concourse

Your 4x slowdown (6min vs 90s) is almost certainly due to **missing layer cache**. On your laptop, Docker reuses cached layers for `npm ci` and `pip install`. In Concourse with your current config, every build starts from scratch.

## Root Cause

`oci-build-task` supports BuildKit cache mounts and image layer caching, but your task config passes no `CACHE_FROM` or `IMAGE_ARG` params. Each build pulls the base image and re-runs every RUN step cold.

## Fix 1: Use `CACHE_FROM` with a registry cache image

Push the built image to a registry after each build, then pull it as cache on the next build. This gives you layer-level caching across workers.

### Updated task config

```yaml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: concourse/oci-build-task
    tag: latest

inputs:
  - name: source
  - name: image-cache
    optional: true

outputs:
  - name: image

params:
  CONTEXT: source
  IMAGE_ARG_CACHE: image-cache/image.tar
  CACHE_FROM: image-cache/image.tar

run:
  path: build
```

### Pipeline setup

You need a two-job pattern: build → push cache, then next build pulls it.

```yaml
resources:
  - name: source
    type: git
    source:
      uri: https://your-repo-url

  - name: app-image
    type: registry-image
    source:
      repository: your-registry/your-app
      tag: cache

jobs:
  - name: build
    plan:
      - in_parallel:
          - get: source
            trigger: true
          - get: app-image
            params:
              format: oci
            passed: []
            # Don't fail if no cache exists yet
      - task: build-image
        privileged: true
        config:
          platform: linux
          image_resource:
            type: registry-image
            source:
              repository: concourse/oci-build-task
              tag: latest
          inputs:
            - name: source
            - name: app-image
          outputs:
            - name: image
          params:
            CONTEXT: source
            CACHE_FROM: app-image/image.tar
          run:
            path: build
      - put: app-image
        params:
          image: image/image.tar
```

The `get: app-image` step fetches the last pushed image as cache. The `put: app-image` step pushes the freshly built image, becoming the cache for the next run.

## Fix 2: Optimize your Dockerfile layer order (do this regardless)

Your `npm ci` and `pip install` steps are slow because they likely run after code COPY steps, busting cache every commit. Reorder:

```dockerfile
# Good: copy dependency files first, install, then copy source
COPY package.json package-lock.json ./
RUN npm ci

COPY requirements.txt ./
RUN pip install -r requirements.txt

# Source copy last — only cache-busts for dep installs when deps change
COPY . .
```

With proper layer ordering + `CACHE_FROM`, dep install layers will be cache hits on most builds (when only source code changed), dropping your build time close to the laptop baseline.

## Fix 3: BuildKit inline cache (alternative to registry cache)

`oci-build-task` uses BuildKit under the hood. You can embed cache metadata in the image:

```yaml
params:
  CONTEXT: source
  BUILD_ARG_BUILDKIT_INLINE_CACHE: "1"
  CACHE_FROM: your-registry/your-app:latest
```

This is simpler than a separate cache resource but requires the image to already be in your registry.

## Expected Results

| Scenario | Build time |
|---|---|
| No cache (current) | ~6 min |
| Cache hit, deps unchanged | ~60–90s |
| Cache miss, only deps changed | ~2–3 min |

With a stable worker pool this approach works well — the cache image in the registry is shared across all workers, so whichever worker picks up the build gets the same cache.

## Notes

- Always pin `concourse/oci-build-task` to a specific digest or version tag rather than `latest` to avoid unexpected breakage.
- The first build after setting this up will still be slow (cold cache). Subsequent builds will be fast.
- If your registry has egress costs, weigh that against CI compute time.
