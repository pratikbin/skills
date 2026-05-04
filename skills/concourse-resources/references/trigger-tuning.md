# trigger-tuning.md — check intervals, webhooks, path scoping, and public visibility

Controls how often Concourse polls for new resource versions, and how to replace polling with push-based webhooks.

---

## check_every

Sets the polling interval for a specific resource, overriding the cluster default.

```yaml
resources:
  - name: release-tag
    type: git
    check_every: 4h          # poll every 4 hours instead of cluster default (~1m)
    source:
      uri: https://github.com/example/app.git
      tag_filter: "v[0-9]*"

  - name: weekly-dep
    type: s3
    check_every: 24h         # slow-changing artifact; no need to poll frequently
    source:
      bucket: upstream-releases
      regexp: deps/tool-([0-9]+\.[0-9]+)\.tar\.gz

  - name: active-source
    type: git
    check_every: 30s         # aggressive polling for a fast feedback loop (use webhooks instead)
    source:
      uri: https://github.com/example/active-repo.git
      branch: main
```

Valid values: any Go duration string (`"30s"`, `"5m"`, `"1h"`, `"24h"`, `"168h"`), or `"never"` to disable polling entirely.

Cluster default is operator-configured (typically `1m`). Overriding to `"never"` stops automated polling; manual check and webhooks still work.

---

## webhook_token

Enables push-based version checking. When a webhook fires, Concourse runs a check immediately instead of waiting for the next poll interval.

```yaml
resources:
  - name: app-src
    type: git
    check_every: never               # disable polling; rely entirely on webhooks
    webhook_token: ((github-wh-token))
    source:
      uri: https://github.com/example/app.git
      branch: main
```

Webhook URL pattern:

```
https://<ATC_EXTERNAL_URL>/api/v1/teams/<TEAM>/pipelines/<PIPELINE>/resources/<RESOURCE>/check/webhook?webhook_token=<TOKEN>
```

Configure this URL in your upstream system (GitHub, GitLab, Docker Hub, etc.) as a webhook target. When the upstream pushes to the URL, Concourse immediately checks for new versions.

Benefits: reduces check container overhead dramatically for repos with infrequent updates; enables near-instant pipeline triggers for repositories with active development.

---

## paths and ignore_paths (git resource)

Scope git check to only relevant subdirectories. Evaluated on the file diff between versions.

```yaml
resources:
  - name: orders-src
    type: git
    source:
      uri: https://github.com/example/monorepo.git
      branch: main
      paths:
        - services/orders/**    # only trigger on these paths
        - libs/shared/**
      ignore_paths:
        - "**/*.md"             # never trigger on markdown files
        - docs/**
        - "**/*.txt"
```

- `paths` — whitelist. A commit is included only if at least one changed file matches a path glob.
- `ignore_paths` — blacklist. A commit is excluded if ALL changed files match ignore globs (or none match the whitelist).
- Both use shell glob patterns (not regexes). `**` matches across directory separators.
- Evaluated on the diff between consecutive versions, not the full tree.

---

## tag_filter (git resource)

```yaml
resources:
  - name: release-tag
    type: git
    check_every: 1h
    source:
      uri: https://github.com/example/app.git
      tag_filter: "v[0-9]*.[0-9]*.[0-9]*"   # glob; match only semver tags
```

Only tags matching the glob are emitted as versions. Without `tag_filter`, all branches and tags matching `branch:` are checked.

---

## public flag

```yaml
resources:
  - name: open-source-repo
    type: git
    public: true              # version history visible without authentication
    source:
      uri: https://github.com/example/oss-project.git
      branch: main
```

`public: true` makes the resource's version history visible via the Concourse API and UI without authentication. Use for open-source pipelines where version metadata (commit refs, timestamps) is not sensitive. Never use for private repos or resources with credentials embedded in version metadata.

---

## Examples

### Monorepo path scoping — independent service pipelines

```yaml
# Pipeline: orders-service
resources:
  - name: monorepo
    type: git
    check_every: never
    webhook_token: ((monorepo-webhook-token))
    source:
      uri: https://github.com/example/monorepo.git
      branch: main
      paths:
        - services/orders/**
        - libs/shared/**
      ignore_paths:
        - "**/*.md"

# Pipeline: payments-service
resources:
  - name: monorepo
    type: git
    check_every: never
    webhook_token: ((monorepo-webhook-token))
    source:
      uri: https://github.com/example/monorepo.git
      branch: main
      paths:
        - services/payments/**
        - libs/shared/**
      ignore_paths:
        - "**/*.md"
```

Both pipelines share the same webhook. Each only triggers on its relevant paths.

---

### Push-driven release pipeline — no polling

```yaml
resources:
  - name: release-tag
    type: git
    check_every: never
    webhook_token: ((release-webhook-token))
    source:
      uri: https://github.com/example/app.git
      tag_filter: "v[0-9]*.[0-9]*"

jobs:
  - name: build-release
    plan:
      - get: release-tag
        trigger: true
      - task: build
      - put: release-artifact
```

GitHub webhook fires on tag push → Concourse immediately checks → job triggers. Latency: seconds, not minutes.

---

### Webhook setup with check_every: never

```yaml
resources:
  - name: heavy-dep
    type: registry-image
    check_every: never
    webhook_token: ((image-webhook-token))
    source:
      repository: ghcr.io/example/heavy-base
      tag: "3.0"
```

Disable polling for images that rarely change. Only update when a webhook fires (e.g., from a GitHub Actions workflow that pushes the image).

---

## Numbers

- Cluster default check interval: ~1 minute (operator-configurable via `CONCOURSE_RESOURCE_CHECKING_INTERVAL`).
- Each check spawns a container. At `1m` with 100 resources = 100 containers/minute. Reduce with longer intervals or webhooks.
- Webhook check is near-instant (< 5 seconds from push to pipeline trigger).
- `check_every: never` + `webhook_token`: zero polling overhead; requires upstream to send webhooks reliably.

---

## Gotchas

- `check_every: never` stops all automated polling. If the webhook system is down, new versions are never detected until a manual check.
- `webhook_token` is a shared secret — store it in your credential manager (`((...))`), not hardcoded.
- `paths`/`ignore_paths` apply only to the `git` resource. Other resource types don't have equivalent filtering.
- `public: true` is a pipeline-level config. The Concourse operator can also configure resources as public at the team or cluster level.

---

## See also

- [git-resource.md](git-resource.md) — `paths`, `ignore_paths`, `tag_filter` full schema
- [schema.md](schema.md) — `check_every`, `webhook_token`, `public`, `tags` fields
- [versioning.md](versioning.md) — `trigger: true`, `version: every`
- [anti-patterns.md](anti-patterns.md) — default `check_every` on slow-changing resources
