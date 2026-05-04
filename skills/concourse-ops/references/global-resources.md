# Global resources

Operator feature that deduplicates resource version checks across pipelines sharing the same resource definition.

## What it does

Without global resources: each pipeline that defines a resource with the same `type` + `source` runs its own independent check loop. 50 pipelines watching the same git repo = 50 check containers per interval.

With global resources enabled: Concourse detects resources with identical `type` + `source` across all teams and pipelines, merges them into a single check. 50 pipelines sharing one check loop.

No pipeline changes required. The deduplication is entirely operator-side.

## Enabling (operator)

```properties
# web node
CONCOURSE_ENABLE_GLOBAL_RESOURCES=true
```

Restart the web node. Takes effect immediately for new checks; existing pipelines dedup on the next check cycle.

## How deduplication works

Two resources are considered "global" (deduplicated) when:
- `type` is identical (by name, must resolve to the same resource type implementation)
- `source` is byte-for-byte identical after serialization

If a resource has `((credentials))` in `source`, those are resolved before comparison. Two resources with the same template but different resolved values are NOT deduplicated.

## Security caveat

**If `source` contains credentials, those credentials are shared across all teams whose resources deduplicate into the same global resource.**

Example risk:
```yaml
# Team A pipeline
resources:
  - name: private-repo
    type: git
    source:
      uri: git@github.com:myorg/private.git
      private_key: ((my-deploy-key))

# Team B pipeline — same source after resolution
resources:
  - name: private-repo
    type: git
    source:
      uri: git@github.com:myorg/private.git
      private_key: ((my-deploy-key))    # same resolved value
```

With global resources, a single check container is created for both. Team B effectively uses Team A's deploy key. This is generally fine if both teams intend to access the same repo, but can be a surprise.

**Do not enable global resources on multi-tenant clusters where teams should not share access.**

## Opting out per resource type

To prevent a specific resource type from deduplicating, set `unique_version_history: true` in the resource type definition:

```yaml
resource_types:
  - name: my-sensitive-type
    type: registry-image
    source:
      repository: myorg/my-resource
    unique_version_history: true   # never deduplicate this type
```

Individual resource instances cannot opt out — it's per resource_type only.

## Monitoring deduplication

With Prometheus metrics enabled, watch:
- `concourse_checks_started_total` — should decrease after enabling
- `concourse_lidar_check_queue_size` — should stabilize lower

## Examples

### Before and after

Before: 20 pipelines each checking `golang:1.22` → 20 check containers running per `check_every` interval.

After enabling `CONCOURSE_ENABLE_GLOBAL_RESOURCES=true`: 1 check container shared by all 20 pipelines.

### Full operator config

```properties
CONCOURSE_ENABLE_GLOBAL_RESOURCES=true
```

That's it. No other changes needed.

## Gotchas

- Deduplication requires `type` AND `source` to match exactly. A single extra whitespace in source YAML prevents dedup.
- `((var))` interpolation happens before comparison. If var values differ across teams, no dedup.
- `unique_version_history: true` on a resource_type opts ALL resources of that type out globally — no fine-grained per-resource control.
- In Concourse < v7, global resources were experimental. In v8 they are stable behind the flag.

## See also

- `references/perf-tuning.md` — check interval tuning, lidar config
- `references/observability.md` — metrics for check queue size
