# Why Your Docker Build Takes 6 Minutes in Concourse (and How to Fix It)

Your task config is missing one line: `caches: [{path: cache}]`. That's the entire explanation.

## What's happening

Without `caches:`, every build starts with a cold BuildKit layer cache. BuildKit has to re-download base images and re-execute every `RUN` step from scratch — including `npm ci` and `pip install -r requirements.txt`. On your laptop, Docker's layer cache is persistent on disk. In Concourse, without `caches:`, that layer cache lives only for the duration of the container and is destroyed when the build finishes.

The `cache` path is where `oci-build-task` tells BuildKit to store its layer cache between runs. It maps directly to BuildKit's `--cache-from type=local,src=...` / `--cache-to type=local,dest=...` under the hood.

## Fix 1: Add the BuildKit layer cache (biggest win, ~2 min saved)

```yaml
# ci/tasks/build-image.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: concourse/oci-build-task
    tag: latest

inputs:
  - name: source

outputs:
  - name: image

caches:
  - path: cache           # <-- this is the only change needed

params:
  CONTEXT: source

run:
  path: build
```

After the first run on a worker, subsequent builds will skip layers whose inputs haven't changed — including the `npm ci` and `pip install` layers if neither `package-lock.json` nor `requirements.txt` has changed.

**Important**: You must also add `privileged: true` to the task step in your pipeline if it isn't already there. BuildKit requires it.

```yaml
# pipeline.yml (relevant excerpt)
- task: build-image
  privileged: true                   # required — BuildKit won't start without this
  file: ci/tasks/build-image.yml
```

## Why your stable worker pool matters here

`caches:` in Concourse are scoped to **worker × pipeline × job-name × step-name × cache-path**. Caches are not shared between workers. With 4–5 stable workers, each one will warm its own cache independently. After a few builds, every worker in the pool will have a warm cache and your 6-minute builds become ~90 seconds — matching your laptop.

If a new worker is added or the job lands on a cold worker, that one run will be slow again. That's expected and correct behavior.

## Fix 2: Optimize your Dockerfile layer order (additional ~30–60s saved on cold cache)

Even with BuildKit caching enabled, you can make cold-cache builds faster — and increase cache hit rate — by ordering your Dockerfile to copy dependency manifests before source code:

```dockerfile
# Copy only dependency files first — these layers are cached until deps change
COPY package.json package-lock.json ./
RUN npm ci

COPY requirements.txt ./
RUN pip install -r requirements.txt

# Copy app source last — changes here don't invalidate the dep install layers above
COPY . .
RUN npm run build
```

If you currently `COPY . .` before `npm ci` or `pip install`, any source file change invalidates the install cache. This structure means the install layers only rebuild when the lockfile/requirements file actually changes.

## Fix 3: Use `--mount=type=cache` in your Dockerfile (optional, more surgical)

For cases where you want the package manager's download cache (not just the layer cache), you can use BuildKit's inline cache mounts. These are stored in the `cache` path managed by `oci-build-task`:

```dockerfile
RUN --mount=type=cache,target=/root/.npm \
    npm ci

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt
```

This mounts a persistent cache directory into the `RUN` step. The layer itself is rebuilt when `package-lock.json`/`requirements.txt` changes, but npm and pip skip re-downloading packages they've already fetched. Combined with Fix 1, this is the fastest possible configuration.

## Summary of changes

| Change | Where | Expected savings |
|--------|-------|-----------------|
| Add `caches: [{path: cache}]` to task.yml | `ci/tasks/build-image.yml` | ~3–4 min on warm cache |
| Add `privileged: true` to task step | `pipeline.yml` | Required for caching to work at all |
| Reorder Dockerfile COPY/RUN | `Dockerfile` | ~30–60s, improves cache hit rate |
| Add `--mount=type=cache` to RUN steps | `Dockerfile` | ~30s additional on partial cache miss |

Fix 1 + the pipeline `privileged: true` are the only required changes. The rest are improvements on top.
