# global-resources.md — operator-side version deduplication across pipelines

Operator feature. When enabled, resources with identical `type` + `source` across all pipelines and teams share a single check loop and version history.

---

## What it does

Without global resources: if 30 pipelines each declare a `git` resource pointing at the same repo with the same `source`, Concourse runs 30 independent check containers every polling interval. Each pipeline maintains its own version history.

With global resources enabled:
- Resources with identical `type` + `source` config are deduplicated into a single "global resource".
- Concourse runs **one** check container per unique (type, source) pair, regardless of how many pipelines reference it.
- All pipelines sharing that (type, source) pair share the same version history.
- Check load: N×N → N.

---

## Operator opt-in

Set the environment variable on the Concourse ATC:

```bash
CONCOURSE_ENABLE_GLOBAL_RESOURCES=true
```

Or in the `concourse web` CLI flags:

```
--enable-global-resources
```

No pipeline config changes required. Once enabled, Concourse automatically identifies and deduplicates identical resources.

---

## Benefits

- Drastically reduces check container count for large installations. 100 pipelines watching the same upstream repo → 1 check loop instead of 100.
- Faster version propagation: a new version detected by the shared check is immediately visible to all consuming resources.
- Consistent versioning: all pipelines see the same version history; no race conditions from independent checks.

---

## The security caveat

**Credentials in `source` are used as part of the deduplication key.**

If pipeline A has:
```yaml
source:
  uri: https://github.com/example/private-repo.git
  private_key: ((team-a.deploy-key))
```

And pipeline B has:
```yaml
source:
  uri: https://github.com/example/private-repo.git
  private_key: ((team-b.deploy-key))
```

These have different `source` configs (different key values after credential interpolation) → they are **not** deduplicated → each runs its own check. This is correct and safe.

But: credential resolution happens at check time. If two pipelines use the same credential variable name and it resolves to the same value (because they share a credential store namespace), they will be deduplicated — and versions discovered by one pipeline's check will be visible in the other pipeline's history.

The more dangerous case is **IAM roles and ambient credentials**:

```yaml
# Pipeline A: runs on workers with IAM role that has S3 access
source:
  bucket: private-bucket
  region_name: us-east-1
  # no explicit credentials — uses instance role

# Pipeline B (attacker): same source config, no credentials
source:
  bucket: private-bucket
  region_name: us-east-1
```

If global resources is enabled, Pipeline B can see all version history discovered by Pipeline A's workers (which had IAM access), even though Pipeline B's workers have no explicit credentials. This is the documented security caveat from Concourse.

> "Anyone could configure the same source:, not specifying any credentials, and see the version history discovered by some other pipeline that ran its checks on workers that had access via IAM roles."

---

## `unique_version_history` — opt out per resource type

```yaml
resource_types:
  - name: my-iam-backed-type
    type: registry-image
    source:
      repository: registry.internal/my-type
    unique_version_history: true    # this type opts out of global resource sharing
```

When `unique_version_history: true`, resources of this type always maintain isolated version histories, even when global resources is enabled cluster-wide. Use for:
- Types that rely on ambient credentials (IAM, GKE Workload Identity, etc.).
- Types where version identity is inherently per-pipeline (e.g., types using `file:` in source, like semver's git driver).
- Types where version leakage between teams is a security concern.

---

## When NOT to use global resources

- Multi-tenant clusters where teams must not see each other's version history.
- When resources use ambient credentials (IAM roles) that vary by worker pool.
- When the `semver` resource type is in use — it requires `unique_version_history: true` because the version file path is part of the source config.

---

## Practical guidance

For an operator enabling global resources on an existing cluster:

1. Audit all resource types in use. Identify any that use ambient credentials.
2. Set `unique_version_history: true` on those resource types before enabling global resources.
3. Enable `CONCOURSE_ENABLE_GLOBAL_RESOURCES`.
4. Monitor check container count — should drop significantly for clusters with many similar resources.

---

## Gotchas

- `unique_version_history` on a `resource_type` has no effect unless `CONCOURSE_ENABLE_GLOBAL_RESOURCES` is set on the ATC.
- Deduplication is based on the resolved `source` values (after credential interpolation), not the raw `((var))` references.
- Enabling global resources changes which check container runs for existing resources. Pipelines may see a brief gap in version detection while Concourse re-associates resources.
- Disabling global resources after enabling it restores independent check loops but does not split the shared version history. Pipelines continue to share the version history that was accumulated.

---

## See also

- [schema.md](schema.md) — `resource_type.unique_version_history`
- [custom-types.md](custom-types.md) — `unique_version_history` in resource_type declarations
- [trigger-tuning.md](trigger-tuning.md) — `check_every` and reducing check load
- [anti-patterns.md](anti-patterns.md) — duplicating same source across pipelines
