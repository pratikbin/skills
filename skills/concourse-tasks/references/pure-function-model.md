# pure-function-model.md

A Concourse task is a pure function: `(inputs, params) → outputs ∪ exit_status`. Nothing else crosses the boundary.

## The invariant

```
inputs:  named directories mounted read-only into /tmp/build/<id>/
params:  env vars set at container start
─────────────────────────────────────────────────
outputs: named directories persisted after exit
status:  0 = success, non-0 = failure
```

No network writes, no database mutations, no side-effects that cross the container boundary — unless you explicitly put them into an output dir and a subsequent `put` step ships them.

Idempotency follows: given the same inputs and params, a correct task produces the same outputs. Run it twice; second run is safe.

## Why pre-baked images beat `apt-get` in `run`

Bad — installs at runtime, flaky, slow, non-reproducible:

```yaml
run:
  path: bash
  args:
    - -ec
    - |
      apt-get update -q
      apt-get install -y --no-install-recommends jq curl
      jq .version source/manifest.json
```

Problems:
- `apt-get update` hits network every build. Fails on mirror outage.
- Package version floats — today's `jq` may not be next week's `jq`.
- Adds 30–90 s per run. Breaks on air-gapped workers.

Good — everything baked into image:

```yaml
image_resource:
  type: registry-image
  source:
    repository: ghcr.io/my-org/ci-tools  # image has jq, curl pre-installed
    tag: "1.3"
  version:
    digest: "sha256:deadbeef..."

run:
  path: bash
  args:
    - -ec
    - jq .version source/manifest.json
```

Build image once, push, pin by digest. Every task run is deterministic.

## Determinism ↔ debuggability

Deterministic tasks are debuggable tasks. `fly execute -c task.yml -i source=.` on your laptop and in CI produce the same result. Flaky task? Either:

1. Task reaches outside inputs (network, time, random, host env).
2. Image is unpinned — different base between runs.
3. Cache state bleeds in (caches are warm on worker, cold on `fly execute`).

Fix all three and `fly intercept` becomes your only debug tool you actually need.

## The pre-baked image build cycle

```
Dockerfile (in source repo)
       │
       ▼
  oci-build-task (CI job: "build-ci-image")
       │
       ▼
  ghcr.io/org/ci-tools:sha-<git-ref>
       │
       ▼ pinned digest in task.yml
  Every task that needs jq, curl, etc.
```

Update cycle: PR changes Dockerfile → CI job rebuilds image → digest updated in task.yml → merged. One change, auditable diff, no runtime surprises.

## Gotchas

- Caches are the one legitimate "state between runs". They're opt-in, clearly declared, and scoped to a worker+job. Still pure: a task must work correctly with an empty cache (first run).
- `params` from the pipeline are not "external state". They're explicit inputs — declared, visible, testable.
- Don't mistake `outputs` persistence for a side-effect. Outputs are part of the function signature.

## See also

- `image-resource.md` — pinning by digest
- `caches.md` — what makes caches OK inside the pure-function model
- `anti-patterns.md` — apt-get in run.args, latest tag
