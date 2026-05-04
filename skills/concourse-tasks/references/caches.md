# caches.md

Persistent directories reused across builds of the same task on the same worker.

## Schema

```yaml
caches:
  - path: node_modules     # relative to task working dir. no leading slash.
  - path: vendor
  - path: .m2/repository
```

`path` is the only field. No name, no key, no TTL.

## Scope

Cache is keyed on: **worker × pipeline × job-name × step-name × cache-path**.

All four must match for a cache hit. Implication:
- Different worker → cold cache.
- Rename the job/step/path → cold cache (old cache orphaned on worker).
- Same job but different pipeline → cold cache.
- `fly execute` one-off builds → **no caches at all**. Cache infrastructure only exists inside pipelines.

## Populate-on-first-run pattern

```yaml
# task.yml — go mod cache example
platform: linux

image_resource:
  type: registry-image
  source:
    repository: golang
    tag: "1.22"

inputs:
  - name: source

outputs:
  - name: bin

caches:
  - path: pkg/mod            # GOPATH/pkg/mod — go module cache

params:
  GOPATH: /tmp/build/put/    # align GOPATH with task workdir parent

run:
  path: bash
  args:
    - -ec
    - |
      cd source
      go mod download          # populates ../pkg/mod on first run; cache hit thereafter
      go build -o ../bin/app ./cmd/app
```

First run: `go mod download` hits the network, fills `pkg/mod`. Subsequent runs on same worker: cache hit, near-zero download time.

## Node modules example

```yaml
caches:
  - path: source/node_modules

run:
  path: bash
  args:
    - -ec
    - |
      cd source
      npm ci                   # installs to node_modules; cached on next run
      npm test
```

Cache key is tied to the step name, not `package-lock.json`. If the lockfile changes, `npm ci` still runs but reuses the existing cache where possible. For a hard reset, rename the step (forces cache miss).

## Maven example

```yaml
caches:
  - path: .m2

params:
  HOME: /tmp/build/put/   # make ~/.m2 resolve into the task workdir

run:
  path: bash
  args:
    - -ec
    - |
      cd source
      mvn -B package -Dmaven.repo.local=../.m2/repository
```

## Why caches are not portable across workers

Concourse does not synchronize caches between workers. Each worker stores its cache independently. When a job lands on a different worker, it cold-starts. Design tasks so cold cache = slower, not broken.

## Why caches don't work with `fly execute`

`fly execute` creates an ad-hoc one-off build. One-off builds have no pipeline/job/step identity, so there is no cache bucket to read from or write to. `caches:` in task.yml is silently ignored. Plan: test caching behavior in a real pipeline job.

## Invalidation

No built-in TTL or content hash. Rename the `path:` (or the step name) to force a miss. Old caches on workers are eventually garbage-collected by the worker's pruning process.

## Gotchas

- Cache path must be inside the task's working directory or a known absolute path (`/root/.cache`). Relative paths are easiest.
- A full cache dir on a worker can fill the worker disk. Set `container_limits` if the cache can grow unbounded.
- Caches across feature branches don't mix (different pipeline-level job identity), which protects branch isolation but means each branch cold-starts.
- For cross-worker or cross-branch caching, see `cache-as-task.md`.

## See also

- `schema.md` — caches field in full task config
- `cache-as-task.md` — cross-worker caching via tarball resource
- `oci-build-task.md` — buildkit layer cache via `caches: [{path: cache}]`
- `anti-patterns.md` — caches with build-id-suffixed paths; caches on fly execute
