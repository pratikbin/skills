# Scoping a Concourse Git Resource to a Monorepo Subdirectory

## The Problem

Without path filters, the `git` resource check emits a new version for **every** commit to `main`, regardless of which files changed. Each of your 5 pipelines subscribes to that same firehose, so all 5 trigger on every commit.

## Corrected Resource YAML

```yaml
resources:
  - name: src
    type: git
    source:
      uri: https://github.com/example/monorepo.git
      branch: main
      paths:
        - services/orders/**
        - libs/shared/**
        - services/orders/tests/**
      ignore_paths:
        - "**/*.md"
```

## What Changed and Why

| Field | Purpose |
|---|---|
| `paths` | Concourse only emits a new version when at least one changed file matches one of these globs. Commits that touch only `services/payments/` or `services/auth/` produce no new version for this resource, so the pipeline is never triggered. |
| `services/orders/**` | Catches all source files under the orders service, including `tests/` (the `**` glob is recursive). |
| `libs/shared/**` | Catches the shared utility code that the orders service depends on. |
| `ignore_paths` | Commits that *only* change matching files are suppressed, even if those files would otherwise match `paths`. A commit touching `services/orders/README.md` alone will not trigger. A commit touching `services/orders/main.go` **and** `services/orders/README.md` *will* trigger (the `.go` file matches `paths` and does not match `ignore_paths`). |

You do **not** need to list `services/orders/tests/**` separately — it is already covered by `services/orders/**`. The `**` glob matches at any depth.

## How Concourse Evaluates the Filters

Concourse diffs the file list between the previously seen commit and the new commit. For each changed file it runs:

1. Does it match any `ignore_paths` glob? → **skip this file**.
2. Does it match any `paths` glob? → **count it as relevant**.

If at least one changed file is counted as relevant, a new resource version is emitted and any job with `trigger: true` on this resource will run. If zero files are relevant, no version is emitted and the pipeline stays idle.

## One Gotcha to Know

On the very first `check` after you deploy this resource (no prior version exists), Concourse will trigger once unconditionally regardless of `paths`. This is expected and documented behavior — it is how Concourse establishes the baseline version.

## Apply the Same Pattern to All 5 Pipelines

Each pipeline gets its own `git` resource with the `paths` list scoped to its own service directory plus any shared libraries it depends on:

```yaml
# payments pipeline
resources:
  - name: src
    type: git
    source:
      uri: https://github.com/example/monorepo.git
      branch: main
      paths:
        - services/payments/**
        - libs/shared/**
      ignore_paths:
        - "**/*.md"
```

With this in place, a commit touching only `services/orders/` will emit a new version for the orders resource only, leaving the other four pipelines idle.
