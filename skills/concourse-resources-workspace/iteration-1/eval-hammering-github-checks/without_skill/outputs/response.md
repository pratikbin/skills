# Reducing GitHub API Rate Limit Hits from Concourse `github-release` Resources

## The Problem

18 pipelines × ~60 checks/hour = **1,080 API calls/hour** for the same GitHub release data. The `github-release` resource type polls GitHub's REST API on every check interval, and each pipeline instance makes independent requests regardless of whether other pipelines are doing the same.

---

## Options

### Option 1: Increase the Check Interval (`check_every`)

The simplest lever. Set a longer interval on the resource in each pipeline.

```yaml
  - name: latest-release
    type: github-release
    check_every: 15m          # was ~1m default
    source:
      owner: example
      repository: shared-lib
      access_token: ((github_token))
```

**Math:** 18 × 4/hour = **72 calls/hour** (15-minute interval).  
**Latency:** You now detect a new release up to 15 minutes late.  
**Downside:** You have to change all 18 pipelines. Still 18 independent callers.

---

### Option 2: Extract a Shared "Notifier" Pipeline + `passed` Constraint

Create one pipeline whose sole job is to detect the release and write an artifact (e.g., a version file) to a shared store (S3, GCS, a git repo). The 18 consumer pipelines watch that artifact — not GitHub directly.

```yaml
# pipeline: release-detector (new, single pipeline)
resources:
  - name: shared-lib-release
    type: github-release
    check_every: 5m
    source:
      owner: example
      repository: shared-lib
      access_token: ((github_token))

  - name: release-version-store
    type: s3
    source:
      bucket: concourse-shared
      versioned_file: shared-lib/latest-release.json
      region_name: us-east-1
      access_key_id: ((aws_access_key))
      secret_access_key: ((aws_secret_key))

jobs:
  - name: publish-release-version
    plan:
      - get: shared-lib-release
        trigger: true
      - task: write-version
        config:
          platform: linux
          image_resource:
            type: registry-image
            source: {repository: alpine, tag: latest}
          inputs:
            - name: shared-lib-release
          outputs:
            - name: version-file
          run:
            path: sh
            args:
              - -c
              - |
                cp shared-lib-release/tag version-file/latest-release.json
      - put: release-version-store
        params:
          file: version-file/latest-release.json
```

Each of the 18 consumer pipelines then watches `release-version-store` instead of GitHub:

```yaml
# In each of the 18 consumer pipelines — replace github-release with s3
resources:
  - name: latest-release
    type: s3
    source:
      bucket: concourse-shared
      versioned_file: shared-lib/latest-release.json
      region_name: us-east-1
      access_key_id: ((aws_access_key))
      secret_access_key: ((aws_secret_key))
```

**Math:** 1 × 12/hour = **12 calls/hour** to GitHub (5-minute check interval on the single detector).  
**Latency:** Up to 5 minutes to detect, then S3 propagation is near-instant.  
**Upside:** 18 pipelines check S3 freely — no rate limit impact. Fire-on-change behavior is fully preserved.

---

### Option 3: Use a Webhook Instead of Polling

Concourse supports inbound webhooks. GitHub can POST to Concourse when a release is published, triggering an immediate resource check on demand rather than on a timer.

On the resource:

```yaml
  - name: latest-release
    type: github-release
    webhook_token: ((concourse_webhook_token))
    check_every: 24h           # fallback polling only, rarely fires
    source:
      owner: example
      repository: shared-lib
      access_token: ((github_token))
```

In GitHub repo settings → Webhooks → Add webhook:

- **Payload URL:** `https://<concourse-url>/api/v1/teams/<team>/pipelines/<pipeline>/resources/latest-release/check/webhook?webhook_token=<token>`
- **Content type:** `application/json`
- **Events:** `Releases`

**Math:** Effectively **0 polling calls** (webhook-driven). The 24h fallback is a safety net.  
**Latency:** Near-zero — GitHub fires the webhook on release publish.  
**Downside:** Requires webhook setup per pipeline (18 webhooks), or you set it up only on the single detector pipeline from Option 2 and combine the approaches.

---

## What I Would Actually Pick

**Option 2 + Option 3 combined** — one detector pipeline with a webhook trigger and a long fallback interval, publishing to S3. The 18 consumers watch S3.

This gives you:
- **Near-zero GitHub API load** (webhook-driven, S3 polling is free)
- **Near-zero detection latency** (fires on release event)
- **One place to maintain** the GitHub credential and check logic
- **No changes needed in consumer pipelines** beyond swapping the resource type

If Option 2's S3 setup feels heavy for your context, **Option 3 alone** (webhook on each pipeline with `check_every: 6h`) is the minimum viable fix and drops calls from 1,080/hour to ~3/hour with instant trigger behavior.

**Option 1 alone** is the least effort but still wasteful — 18 independent callers is the root problem regardless of interval.

---

## Summary Table

| Option | API calls/hour | Detection latency | Effort |
|---|---|---|---|
| Current (default ~1m) | ~1,080 | ~1 min | — |
| 1. Longer `check_every` (15m) | ~72 | ~15 min | Low |
| 2. Shared detector + S3 | ~12 (GitHub), ~72 (S3) | ~5 min | Medium |
| 3. Webhooks on all 18 | ~3 | seconds | Medium |
| **2 + 3 (recommended)** | **~1 fallback/day** | **seconds** | Medium |
