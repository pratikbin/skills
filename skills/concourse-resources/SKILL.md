---
name: concourse-resources
description: Use whenever the user is configuring, picking, or tuning Concourse resources or resource types — `git`, `registry-image`, `time`, `semver`, `s3`, `pool`, custom resource types, source/params blocks, version pinning (`tag`, digest, `semver_constraint`, `version: latest|every|{ref:X}`), trigger filtering (`paths`, `ignore_paths`, `tag_filter`, `check_every`, `webhook_token`), `no_get`/`skip_download`, or operator-level concerns (global resources, custom resource_types). Trigger on phrases like "git resource", "registry-image", "trigger only on path X", "ignore paths", "version pinning", "tag filter", "check_every", "skip download", "custom resource type", "stop checking every minute", "pin to digest", "global resources", "version: every default", and proactively whenever a `resources:` or `resource_types:` block is being added or modified. Based on Concourse v8+ docs and concourse/ci real-world pipelines + the official `git`, `registry-image`, `time`, `semver`, `s3`, `pool`, `oci-build-task` resource READMEs.
---

# concourse-resources

Practical playbook for **picking, configuring, and tuning Concourse resources and resource types**. Tells you **what to write**, **why it cuts check load and false triggers**, and **when to leave defaults alone**. Targets the schema as of Concourse v8+ — confirm with `fly validate-pipeline` before relying.

## When to use this skill

Activate whenever the work touches a `resources:` or `resource_types:` block, or any field that controls how Concourse fetches, filters, or pushes external state. Examples:

- "which resource type should I use for X"
- "how do I skip the download on a put"
- "this pipeline triggers every minute even when nothing changed"
- "pin this image by digest"
- "monorepo: only trigger when `apps/foo/` changes"
- "we have 30 pipelines all checking the same git repo every minute"
- "should I write a custom resource type or just script it in a task"
- "the version-bumping is going backwards"

For pipeline-level structure (jobs, plans, steps, parallelism, hooks) → `concourse-pipeline`. For task config (`task.yml`, `image_resource`, `caches:`) → `concourse-tasks`. For `fly`/credentials/teams/perf-tuning → `concourse-ops`.

## Core mental model

1. **A resource is a versioned external thing.** Concourse `check`s it on an interval, fetches versions on `get`, and pushes new versions on `put`. The resource's *type* says how to do those three things.
2. **`source` configures the type, `params` configures the operation.** `source` lives on the `resource` (where to look, with what credentials). `params` lives on each `get`/`put` step (what to do with this version).
3. **Check load grows linearly with resource count × pipeline count.** A pipeline with 10 resources at the default `check_every: 1m` is 10 checks/minute *per pipeline*. Multiply by N pipelines that share a resource and you can saturate a Concourse cluster trivially. Two knobs cut this: per-resource `check_every`, and operator-side global resources.
4. **Triggering is filtered three ways.** (a) `trigger: true` on a `get` — without it, a new version is a *constraint*, not a *trigger*. (b) Source-level filters that don't even produce a version: `paths`/`ignore_paths` (git), `tag_filter`/`pre_release`/`variant` (registry-image), `semver_constraint`. (c) `webhook_token` flips check from polling to push.
5. **`put` implicitly does a `get`.** After a successful push, Concourse `get`s the new version into the build's artifact namespace. Set `no_get: true` (and/or `params.skip_download` on s3-style) when you don't need the artifact downstream — saves time and disk.

## Decision tree — pick the right reference

Match the symptom or question to a reference, then read that file for schema, examples, and gotchas.

```
Symptom / question                                        → Read first
─────────────────────────────────────────────────────────────────────────────
"resource{} / resource_type{} schema"                     → references/schema.md
"which resource type should I pick for X?"                → references/core-types.md
"git resource — paths, ignore_paths, tag_filter, depth"   → references/git-resource.md
"registry-image — pin by digest / semver / variant"       → references/registry-image.md
"time resource — interval, hours, location"               → references/time-resource.md
"semver resource — bump rules, driver"                    → references/semver-resource.md
"s3 resource — versioned_file vs regexp, skip_download"   → references/s3-resource.md
"pool — env locks, manual gates"                          → references/pool-resource.md
"how does `get`/`put` versioning work? `version: every`?" → references/versioning.md
"trigger only on certain paths / ignore vendored files"   → references/trigger-tuning.md
                                                            + references/git-resource.md
"check is hammering my GitHub / private registry"         → references/trigger-tuning.md (check_every,
                                                            webhook_token) + references/global-resources.md
"webhook to push commits to concourse instead of polling" → references/trigger-tuning.md (webhook_token)
"custom resource type — when worth writing one?"          → references/custom-types.md
"30 pipelines watch same repo — dedup the checks?"        → references/global-resources.md (operator)
"smell test — is this resource config wrong?"             → references/anti-patterns.md
```

## Fast defaults (copy-paste-ready)

These bias toward fewer false triggers and lower check load. Read the linked reference before tweaking the values.

### Pin a registry image by digest, fall back to a semver_constraint

`tag: latest` produces silent breakage when the image changes upstream. Pin or constrain. See `references/registry-image.md`.

```yaml
# Most reproducible: pinned digest. Updates only when you bump the digest.
- name: app-image
  type: registry-image
  source:
    repository: ghcr.io/example/app
    tag: "1.4.2"
    # OR: pin to a digest with no tag
    # pre_release: false
    # semver_constraint: ">=1.4 <2"   # if you want auto minor bumps
    username: ((registry.username))
    password: ((registry.password))
```

### Git resource for a monorepo: only trigger on relevant paths

A monorepo will trigger every consumer pipeline on every commit unless you scope it. See `references/git-resource.md`.

```yaml
- name: app-src
  type: git
  source:
    uri: https://github.com/example/monorepo.git
    branch: main
    paths:
      - apps/orders/**
      - libs/shared/**
    ignore_paths:
      - "**/*.md"
      - "**/CHANGELOG"
```

### Slow down checks for resources that don't change often

Every resource defaults to ~1m check intervals (cluster-tunable). For a release tag, an artifact bucket, or a hand-bumped pin file, that's wasteful. See `references/trigger-tuning.md`.

```yaml
- name: latest-release
  type: github-release
  check_every: 30m         # release cadence is hours/days, not seconds
  webhook_token: ((webhook_secret))   # let GitHub poke us between checks
  source:
    owner: example
    repository: app
```

### Skip the implicit `get` after a `put`

Pushing a 2GB tarball back into the build context after a `put` is pure waste if nothing downstream needs it. See `references/versioning.md`.

```yaml
- put: app-image
  no_get: true
  params:
    image: build/image.tar
```

For s3 specifically, when even the put-side download is heavy (large versioned files), use `skip_download` on the get/put params per the s3-resource README.

## When NOT to optimize

- **A resource that produces a few versions a day.** Default `check_every` is fine. Squeezing it doesn't matter.
- **`tag: latest` for a strictly internal builder image you control end-to-end.** Reproducibility doesn't apply if you also control when the upstream changes. (Still prefer digest pin in CI for production.)
- **`paths:` for a single-app repo.** It just adds a foot-gun (forget to update when adding a directory) for no real benefit.
- **Custom resource type for a one-off integration.** A scripted task is cheaper to write, easier to debug, and avoids the privileged-container blast radius. See `references/custom-types.md`.

## Anti-pattern flags

If reviewing an existing pipeline, scan first for these. See `references/anti-patterns.md` for full list.

- `check_every` left at default (1m) on resources that change once a day.
- Time resource with `interval: 1m` driving a heavy job — every tick triggers.
- Monorepo `git` resource with no `paths` / `ignore_paths` → every commit fires every pipeline.
- `registry-image` source with `tag: latest` and no digest / semver_constraint → silent upstream breakage.
- `version: every` on a high-commit-rate repo → backlog of builds.
- `put` step that doesn't need its result downstream but lacks `no_get: true`.
- Missing `webhook_token` on resources whose upstream supports webhooks.
- Same source config repeated across pipelines without operator-side global resources.
- Custom resource type written to wrap a 5-line shell call.

## Cross-references

- `concourse-pipeline` — when the question is about `passed:`, fan-in/fan-out, in_parallel, or step composition.
- `concourse-tasks` — when the question is about consuming a fetched artifact, `caches:`, or building images via `oci-build-task`.
- `concourse-ops` — `fly check-resource`, vars/var_sources, secret managers, performance tuning at the cluster level (including operator-side global resources).
