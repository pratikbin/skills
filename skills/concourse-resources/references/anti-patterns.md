# anti-patterns.md — common resource config mistakes and how to fix them

Each entry describes a real mistake, explains why it hurts, and shows the fix.

---

## 1. Default check_every on slow-changing resources

WRONG — polls every minute for a release tag that ships monthly (default `check_every` is ~1m). RIGHT — set a longer interval or disable polling with a webhook:

```yaml
resources:
  - name: upstream-release
    type: git
    check_every: 24h            # or: check_every: never + webhook_token
    source:
      uri: https://github.com/upstream/tool.git
      tag_filter: "v[0-9]*"
```

Every check spawns a container. 100 slow-changing resources × 1m = 100 wasted container starts per minute.

---

## 2. time interval: 1m driving heavy jobs

WRONG — `interval: 1m` with a 10-minute job; builds queue 10-deep in minutes. RIGHT — match the interval to the job cadence:

```yaml
resources:
  - name: every-hour
    type: time
    source:
      interval: 1h   # or use start/stop window, or a git trigger instead

jobs:
  - name: integration-suite
    plan:
      - get: every-hour
        trigger: true
      - task: run-integration
```

---

## 3. Monorepo git without paths/ignore_paths

WRONG — no `paths` set; every commit in the monorepo triggers every consumer pipeline. RIGHT:

```yaml
resources:
  - name: orders-src
    type: git
    source:
      uri: https://github.com/example/monorepo.git
      branch: main
      paths: [services/orders/**, libs/shared/**]
      ignore_paths: ["**/*.md"]
```

In a 20-service monorepo, omitting `paths` triggers all service pipelines on every commit to any service.

---

## 4. tag: latest on registry-image without digest pinning

WRONG — silent breakage when image is re-pushed:

```yaml
resources:
  - name: base-image
    type: registry-image
    source:
      repository: ubuntu
      tag: latest          # mutable; changes silently when upstream pushes
```

RIGHT — pin to a fixed tag, semver_constraint, or digest:

```yaml
resources:
  - name: base-image
    type: registry-image
    source:
      repository: ubuntu
      tag: "24.04"                   # fixed tag; or semver_constraint: ">=24 <25"
    version:
      digest: "sha256:abc123..."    # pipeline-level digest pin; byte-identical builds
```

`latest` is opaque. Two builds on the same day may use different images.

---

## 5. version: every default on a high-commit-rate repo

WRONG — processes 200 commits queued during the weekend:

```yaml
jobs:
  - name: changelog-builder
    plan:
      - get: source
        version: every     # queues one build per commit
        trigger: true
      - task: slow-build   # takes 5 minutes
```

200 commits × 5 minutes = 1000 minutes of queue. Builds run for days after a weekend.

RIGHT — use `version: every` only when you genuinely need to process every commit in order:

```yaml
jobs:
  - name: changelog-builder
    plan:
      - get: source
        version: latest    # process only the latest; skip the backlog
        trigger: true
```

If you do need every commit (e.g., changelog generation), add a max-in-flight or accept the queue. Never use `version: every` on fast-moving repos with slow jobs without a plan for queue management.

---

## 6. Missing no_get: true on heavy puts

WRONG — downloads a 2GB image back immediately after pushing it:

```yaml
jobs:
  - name: build-and-push
    plan:
      - task: build-image
        # produces build/image.tar (2GB)
      - put: app-image
        # Concourse implicitly runs get after put — downloads 2GB back into the build
        params:
          image: build/image.tar
```

RIGHT — skip the implicit get when the build doesn't need the artifact back:

```yaml
      - put: app-image
        no_get: true       # skip implicit get; saves 2GB download + container overhead
        params:
          image: build/image.tar
```

Or use `get_params` to get metadata without bytes:

```yaml
      - put: app-image
        params:
          image: build/image.tar
        get_params:
          skip_download: true    # version metadata only; no layer download
```

---

## 7. Missing webhook_token for upstreams that support it

WRONG — polling every minute for a GitHub repo that sends push events:

```yaml
resources:
  - name: source
    type: git
    # check_every: 1m (default) — wastes check containers
    source:
      uri: https://github.com/example/app.git
      branch: main
```

RIGHT — disable polling and use webhooks:

```yaml
resources:
  - name: source
    type: git
    check_every: never
    webhook_token: ((github-webhook-token))
    source:
      uri: https://github.com/example/app.git
      branch: main
```

Then configure a GitHub webhook pointing to:
`https://<ATC>/api/v1/teams/main/pipelines/my-pipeline/resources/source/check/webhook?webhook_token=<TOKEN>`

Webhooks reduce trigger latency from ~1m to seconds, and eliminate check container overhead entirely.

---

## 8. Duplicating same source across pipelines without global resources opt-in

WRONG — 50 pipelines each checking the same upstream git repo:

```yaml
# Pipeline 1
resources:
  - name: golang-src
    type: git
    source:
      uri: https://github.com/golang/go.git
      branch: master

# Pipeline 2 (identical source)
resources:
  - name: golang-src
    type: git
    source:
      uri: https://github.com/golang/go.git
      branch: master
```

50 independent check loops → 50 check containers per interval.

RIGHT — ask the operator to enable global resources (`CONCOURSE_ENABLE_GLOBAL_RESOURCES=true`). With this enabled, all 50 pipelines share one check loop. No pipeline changes needed. Read the IAM security caveat in [global-resources.md](global-resources.md) first.

---

## 9. Custom resource type wrapping a trivial shell call

WRONG — a full resource type container image for a single HTTP health check (no version semantics, no trigger need).

RIGHT — use a task instead:

```yaml
jobs:
  - name: deploy-and-verify
    plan:
      - task: check-health
        config:
          platform: linux
          image_resource:
            type: registry-image
            source: {repository: curlimages/curl, tag: "8.7.1"}
          run:
            path: curl
            args: [--fail, --silent, https://api.internal/health]
```

If the integration has no version semantics, a task is always simpler. Write a custom resource type only when you need check/trigger/version tracking.

---

## 10. passed: on a put step (invalid)

WRONG — `passed:` is not valid on a `put` step:

```yaml
jobs:
  - name: deploy
    plan:
      - put: app-image
        passed: [test]     # INVALID — fly set-pipeline will reject this
        params:
          image: build/image.tar
```

`passed:` is only valid on `get` steps. A `put` creates a new version; it doesn't select from prior ones. Gate before the `put` using `get` with `passed:`:

```yaml
jobs:
  - name: deploy
    plan:
      - get: source
        trigger: true
        passed: [test]      # gate on test passing — valid on get
      - task: build
      - put: app-image
        params:
          image: build/image.tar
```

---

## 11. Using put as a job trigger

WRONG — trying to trigger a job when a put completes:

```yaml
jobs:
  - name: downstream-job
    plan:
      - put: app-image      # INVALID as trigger source
        trigger: true       # put steps do not have a trigger field
```

`trigger:` is only valid on `get` steps. To chain off a `put`, use `get` of the same resource with `passed:` in the downstream job:

```yaml
jobs:
  - name: upstream-job
    plan:
      - put: app-image
        params: {image: build/image.tar}

  - name: downstream-job
    plan:
      - get: app-image
        trigger: true
        passed: [upstream-job]    # triggers when upstream-job's put produces a new version
      - task: deploy
```

---

## See also

- [trigger-tuning.md](trigger-tuning.md) — `check_every`, webhooks, path scoping
- [versioning.md](versioning.md) — `version: every`, `passed:`, `no_get: true`
- [global-resources.md](global-resources.md) — dedup checks across pipelines
- [time-resource.md](time-resource.md) — interval pitfalls
- [custom-types.md](custom-types.md) — when a task wins over a resource type
