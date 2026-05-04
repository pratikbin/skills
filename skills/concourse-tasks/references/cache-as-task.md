# cache-as-task.md

Cross-worker / cross-branch dependency caching via an explicit tarball resource. Meshcloud pattern.

## Problem

Concourse native `caches:` are scoped to one worker. Jobs spread across workers always cold-start. For slow `npm ci` / `go mod download` / `mvn -B package`, this kills build time at scale.

## Solution

Make dependency installation a separate job. Upload the result as a versioned artifact (tarball keyed by lockfile hash). Downstream jobs `get` the tarball and untar it — no network fetch, any worker.

## Trade

| Aspect | Native caches | Cache-as-task |
|---|---|---|
| Portability | Worker-local | Any worker |
| Branch isolation | Job-scoped | Key-scoped (lockfile) |
| Extra complexity | None | Extra job + resource |
| `fly execute` support | No | Yes (get tarball locally) |

Use cache-as-task when: jobs run on 3+ workers, cold-start costs >2 min, or branches heavily share the same lockfile.

## Sample pipeline

```yaml
# pipeline.yml

resources:
  - name: source
    type: git
    source:
      uri: https://github.com/org/repo.git
      branch: main

  - name: node-cache
    type: s3
    source:
      bucket: ci-caches
      access_key_id: ((aws-access-key))
      secret_access_key: ((aws-secret-key))
      regexp: node_modules-(.*).tar.gz

jobs:
  - name: prepare-deps
    plan:
      - get: source
        trigger: true
      - task: install-deps
        file: ci/tasks/prepare-deps.yml
        output_mapping:
          cache-tarball: node-cache-artifact
      - put: node-cache
        params:
          file: node-cache-artifact/node_modules-*.tar.gz

  - name: test
    plan:
      - get: source
        trigger: true
        passed: [prepare-deps]
      - get: node-cache
        passed: [prepare-deps]
      - task: run-tests
        file: ci/tasks/test.yml
        input_mapping:
          deps-cache: node-cache
```

## prepare-deps task

```yaml
# ci/tasks/prepare-deps.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: node
    tag: "20-bookworm-slim"
  version:
    digest: "sha256:abc123..."

inputs:
  - name: source

outputs:
  - name: cache-tarball

run:
  path: bash
  args:
    - -ec
    - |
      cd source
      npm ci
      LOCKFILE_HASH=$(sha256sum package-lock.json | cut -c1-12)
      tar -czf ../cache-tarball/node_modules-${LOCKFILE_HASH}.tar.gz node_modules
```

## test task

```yaml
# ci/tasks/test.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: node
    tag: "20-bookworm-slim"
  version:
    digest: "sha256:abc123..."

inputs:
  - name: source
  - name: deps-cache
    optional: true

run:
  path: bash
  args:
    - -ec
    - |
      # Restore cache if available
      if ls deps-cache/*.tar.gz 1>/dev/null 2>&1; then
        tar -xzf deps-cache/*.tar.gz -C source/
      else
        cd source && npm ci  # fallback: cold install
        cd ..
      fi
      cd source
      npm test
```

## Key design points

- Lockfile hash in the tarball filename lets the S3 resource version naturally rotate when dependencies change.
- `prepare-deps` job only triggers when `source` changes (lockfile included). If lockfile unchanged, no new tarball.
- `test` makes `deps-cache` optional with a fallback install. Safe to run standalone with `fly execute`.
- S3 resource `regexp` matches on the hash-stamped filename, so versioning is automatic.

## Gotchas

- Tarball can grow large (node_modules for large projects: 200 MB+). Monitor S3 costs.
- The `prepare-deps` job is a serial bottleneck when multiple PRs trigger in parallel.
- If `optional: true` fallback is removed, test job fails when no cache exists yet (cold pipeline).

## See also

- `caches.md` — native cache mechanism (worker-local)
- `inputs-outputs.md` — how output dirs are passed between tasks
- `anti-patterns.md` — caches on fly execute
