# Fixing Slow Concourse Unit Task

## The Problem

Your task installs Node.js, npm, and yarn from scratch on every single run using a bare `debian:bookworm-slim` image. That's the 90 seconds of overhead you're seeing. With 50 runs/day, that's ~75 minutes of pure package installation time wasted daily.

## The Fix: Use a Pre-built Image

The correct solution is to use a Docker image that already has Node.js and yarn installed, so your task starts with the tools ready.

### Option 1: Official Node.js image (recommended)

```yaml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: node
    tag: 20-bookworm-slim

inputs:
  - name: source

outputs:
  - name: junit

run:
  path: bash
  args:
    - -ec
    - |
      cd source
      yarn install
      yarn test --reporter junit --output-file ../junit/results.xml
```

This eliminates the `apt-get` installs entirely. The `node:20-bookworm-slim` image ships with Node.js and npm pre-installed. You only need to add yarn:

```yaml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: node
    tag: 20-bookworm-slim

inputs:
  - name: source

outputs:
  - name: junit

run:
  path: bash
  args:
    - -ec
    - |
      npm install -g yarn
      cd source
      yarn install
      yarn test --reporter junit --output-file ../junit/results.xml
```

But yarn installation still adds a few seconds. Go further.

### Option 2: Use a custom project image (best for teams)

Build and push a single Docker image that has everything pre-installed. Put this in a `Dockerfile` in your repo or a separate `tools` repo:

```dockerfile
FROM node:20-bookworm-slim
RUN npm install -g yarn
```

Push it to your registry (e.g., `your-registry/ci-node:20`), then use it in your task:

```yaml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: your-registry/ci-node
    tag: "20"

inputs:
  - name: source

outputs:
  - name: junit

run:
  path: bash
  args:
    - -ec
    - |
      cd source
      yarn install
      yarn test --reporter junit --output-file ../junit/results.xml
```

Now `yarn install` is the only setup step. If your `node_modules` are relatively stable, consider caching the yarn cache directory using a Concourse cache resource or by baking a `yarn install` into your CI image build.

### Option 3: Cache node_modules between runs (advanced)

If you want to go further, use a Concourse cache to persist `node_modules` across runs. This requires a resource type that supports caching (like `s3-resource` or a Concourse cache volume), but the image change alone will get you most of the way there.

## Expected Impact

| Approach | Setup time | Total time |
|---|---|---|
| Current (apt-get on debian:slim) | ~90s | ~120s |
| node:20-bookworm-slim + global yarn install | ~10s | ~40s |
| Custom image with yarn pre-installed | ~2s | ~32s |

## Summary

- **Root cause**: Installing system packages at runtime on a bare OS image is inherently slow.
- **Fix**: Switch to `node:20-bookworm-slim` or a custom image that has Node.js + yarn pre-installed.
- **Minimum change**: Replace the `image_resource` and remove the `apt-get` lines.
- **Best practice**: Build a dedicated CI image with all your tools baked in, version it, and update it on a schedule separately from your application builds.
