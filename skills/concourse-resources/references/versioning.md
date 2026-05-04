# versioning.md — version selection, passed constraints, and implicit get-after-put

Controls which version of a resource a job sees: latest, every, pinned, or filtered through prior jobs.

---

## get step version field

```yaml
- get: my-repo
  version: latest       # default; fetch the newest version known to Concourse
  # version: every      # trigger the job once per version, in order
  # version: {ref: abc123def456}   # pin to an exact version key
  trigger: true         # optional; schedule a new build when a new version appears
  passed: [job-a, job-b]  # optional; only fetch versions that have passed these jobs
  params: {}            # optional; arbitrary map passed to the resource's `in` script
```

### `version:` values

| value | behavior |
|---|---|
| `latest` | (default) fetch the single newest version; job runs once per trigger event |
| `every` | Concourse queues one build per version in chronological order; good for processing every commit |
| `{key: value}` | pin to a specific version; use the version map fields the resource type emits |

---

## passed: filter

```yaml
jobs:
  - name: deploy
    plan:
      - get: source
        trigger: true
        passed: [test, security-scan]   # only versions that have passed BOTH jobs
```

`passed` creates a version pipeline: only versions that have flowed through all listed jobs are eligible. Versions that failed or haven't yet run those jobs are invisible to this step.

Rules:
- All jobs in `passed` must have already done a `get` of the same resource (or a resource that shares the same version lineage).
- `passed` is only valid on `get` steps — not on `put` steps.
- Multiple resources with `passed` on the same job create a fan-in: all constrained resources must have a compatible version set.

---

## put step — implicit get-after-put

After every `put`, Concourse automatically runs a `get` to fetch the version just created back into the build. This gives you the version metadata and any artifacts the resource deposited.

```yaml
- put: app-image
  params:
    image: build/image.tar
# Concourse implicitly runs:
# - get: app-image
#   version: {digest: sha256:...}  (the version just pushed)
```

Control the implicit get with `get_params`:

```yaml
- put: app-image
  params:
    image: build/image.tar
  get_params:
    skip_download: true     # fetch metadata but not the image layers
```

Skip it entirely with `no_get: true`:

```yaml
- put: app-image
  no_get: true              # no implicit get; saves time for large artifacts
  params:
    image: build/image.tar
```

---

## Examples

### Pinned-version regression test

Run a job against a specific known-good version (e.g., to reproduce a bug):

```yaml
resources:
  - name: source
    type: git
    source:
      uri: https://github.com/example/app.git
      branch: main
    version:
      ref: "deadbeef1234"    # pipeline-level pin; all gets use this version

jobs:
  - name: regression-test
    plan:
      - get: source          # fetches the pinned ref
        trigger: false       # don't auto-trigger; run manually
      - task: test
```

To unpin, remove the `version:` block from the resource and re-fly the pipeline.

---

### version: every for changelog generation — process every commit

```yaml
resources:
  - name: source
    type: git
    source:
      uri: https://github.com/example/app.git
      branch: main

jobs:
  - name: generate-changelog
    plan:
      - get: source
        version: every       # one build per commit, in order
        trigger: true
      - task: append-changelog-entry
        # uses source/.git/commit_message, source/.git/short_ref, etc.
      - put: changelog-bucket
        params:
          file: changelog/entry.txt
```

Concourse queues builds and processes each commit in order. If 5 commits land while the job is busy, 5 builds queue up — not just 1.

---

### no_get: true on a notification put — skip post-put download

```yaml
jobs:
  - name: deploy
    plan:
      - get: source
        trigger: true
        passed: [test]
      - task: deploy
      - put: slack-notify
        no_get: true        # slack resource has nothing to download
        params:
          channel: "#deploys"
          text: "Deployed $BUILD_PIPELINE_NAME #$BUILD_NAME"
```

Notification resources (Slack, GitHub status, PagerDuty) don't produce meaningful get output. `no_get: true` avoids a pointless container spin-up.

---

### Fan-in with passed — require two upstream jobs

```yaml
jobs:
  - name: integration-test
    plan:
      - get: source
        trigger: true
        passed: [unit-test]

  - name: deploy-staging
    plan:
      - get: source
        trigger: true
        passed: [integration-test]   # only after integration-test passes

  - name: deploy-prod
    plan:
      - get: source
        trigger: false
        passed: [deploy-staging, security-scan]  # BOTH must have passed
      - task: deploy-prod
```

`deploy-prod` only sees versions where both `deploy-staging` and `security-scan` have succeeded. If either fails, the version is invisible to `deploy-prod`.

---

## Gotchas

- `version: every` with a high-commit-rate repo will queue many builds. If each build is slow, the queue grows unbounded. Use only when you truly need to process every version in order.
- `passed:` on a `put` step is invalid and will fail pipeline validation. Only use `passed:` on `get` steps.
- `version: {key: value}` — the key must match the version schema the resource type emits. For git, the key is `ref`. For registry-image, it's `digest`. Check what your resource type emits.
- The implicit get-after-put runs in the same build. If it fails (e.g., registry is temporarily unavailable), the build fails even though the push succeeded.
- `get_params` vs `no_get: true` — use `get_params: {skip_download: true}` when you want version metadata without bytes. Use `no_get: true` when you want neither.

---

## See also

- [trigger-tuning.md](trigger-tuning.md) — `trigger: true`, `check_every`, webhooks
- [schema.md](schema.md) — pipeline-level `version:` on resource declaration
- [anti-patterns.md](anti-patterns.md) — `version: every` on high-commit repos, missing `no_get`
