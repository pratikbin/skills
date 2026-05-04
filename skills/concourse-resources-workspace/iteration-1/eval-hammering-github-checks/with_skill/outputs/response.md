# Fixing GitHub API Rate Limit Hammering: 18 Pipelines, Same Repo

You have three levers. The right answer is a combination of two of them.

---

## Option 1: Raise `check_every` (slowdown)

Set a longer poll interval on every resource. Reduces frequency but doesn't eliminate polling.

```yaml
  - name: latest-release
    type: github-release
    check_every: 1h          # was ~1m; now 18 × 1/hour = 18 checks/hour
    source:
      owner: example
      repository: shared-lib
      access_token: ((github_token))
```

**Math**: 18 pipelines × 1 check/hour = 18 requests/hour. Down from 1080.

**Tradeoff**: You may wait up to 1 hour after a new release before pipelines trigger. Acceptable for most library consumers; not acceptable if you need near-instant reaction.

---

## Option 2: Global Resources (operator opt-in, best for identical sources)

Because all 18 pipelines use **identical** `type` + `source`, the operator can enable global resources. Concourse deduplicates them into one check loop cluster-wide — all 18 pipelines share that single check result.

Enable on the ATC:

```bash
# In the worker/ATC environment (concourse web component)
CONCOURSE_ENABLE_GLOBAL_RESOURCES=true
```

Or in your BOSH/Helm/docker-compose deployment config:

```
concourse web --enable-global-resources
```

Once enabled, your resource config needs **no changes** in the pipelines. Concourse sees the same `type: github-release` + same `source:` block across 18 pipelines and runs a **single** check container. All 18 pipelines get the version update from that one check.

**Math**: 1 check/minute (or whatever the cluster default is) regardless of how many pipelines use it. Down from 1080/hour to 60/hour, and if you also raise `check_every` on the resource, even lower.

**Requirement**: The `source:` blocks must be byte-for-byte identical after credential resolution. If any pipeline resolves `((github_token))` to a different value, those resources won't be deduplicated. Since they all use the same credential name pointing to the same token, you're fine.

**Security note**: Global resources share version history across pipelines. Any pipeline that can read this resource's versions can see what all other pipelines have fetched. For a public GitHub release, this is a non-issue.

---

## Option 3: Webhook + `check_every: never` (push-driven, zero polling)

Register a GitHub webhook that fires on releases, pointed at each pipeline's resource webhook URL. Disable polling entirely.

Resource config (same change in all 18 pipelines, same token is fine):

```yaml
  - name: latest-release
    type: github-release
    check_every: never
    webhook_token: ((shared-lib-webhook-token))
    source:
      owner: example
      repository: shared-lib
      access_token: ((github_token))
```

Webhook URL per pipeline (register all 18 in GitHub, or use one if global resources handles dedup):

```
https://<ATC_EXTERNAL_URL>/api/v1/teams/<TEAM>/pipelines/<PIPELINE>/resources/latest-release/check/webhook?webhook_token=<TOKEN>
```

In GitHub → repo settings → Webhooks → add webhook, content type `application/json`, event: **Releases**.

**Math**: 0 polling. Checks only fire when GitHub pushes the webhook.

**Tradeoff**: If GitHub's webhook delivery fails (outage, retry exhaustion), you never learn about a new release until someone manually triggers a check. You lose the self-healing property of polling.

---

## What I Would Actually Pick

**Global resources + moderate `check_every` as a fallback safety net.**

```yaml
  - name: latest-release
    type: github-release
    check_every: 30m        # safety net: catch any missed webhook or just poll slowly
    source:
      owner: example
      repository: shared-lib
      access_token: ((github_token))
```

1. **Enable global resources on the cluster** — one operator change, zero pipeline changes. Drops your 1080 checks/hour to 2/hour (one check every 30 minutes). Immediate, low-risk.

2. **Set `check_every: 30m`** on the resource in all 18 pipelines — with global resources active, this means one check per 30 minutes cluster-wide, not 18.

3. **Optionally add a webhook** on top — gives you near-instant trigger (<5 seconds) when a real release drops, while the 30-minute poll remains as a backstop.

Why not webhook-only (`check_every: never`)?  
Because `github-release` webhooks require GitHub to reliably deliver release events to 18 URLs (or 1 URL if global resources consolidates them). The polling backstop is cheap insurance. 30 minutes is acceptable lag for a library consumer reacting to a new release.

Why not just raise `check_every` without global resources?  
It works, but it leaves 18 independent check processes running where 1 will do. Global resources is the correct fix for identical sources — it's what the feature exists for.

---

## Summary

| Option | Requests/hour after | Latency | Effort |
|--------|--------------------|---------|----|
| Default (current) | 1080 | ~1 min | — |
| `check_every: 1h` only | 18 | up to 1h | Low (18 YAML edits) |
| Global resources + `check_every: 30m` | 2 | up to 30 min | Low (1 operator flag + 18 YAML edits) |
| Global resources + webhook + `check_every: 30m` | 2 + event-driven | seconds on release, 30 min backstop | Medium (above + GitHub webhook setup) |
| Webhook + `check_every: never` | ~0 | seconds | Medium (no backstop) |
