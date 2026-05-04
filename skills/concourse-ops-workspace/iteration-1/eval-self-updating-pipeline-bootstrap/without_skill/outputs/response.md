# Self-Updating Concourse Pipelines: Bootstrap Pattern

## The Problem

Manual `fly set-pipeline` steps are fragile:
- People forget to run them after merging
- Pipelines silently run stale config for days/weeks
- The unpause step gets skipped, leaving pipelines paused

## The Solution: Meta-Pipeline Pattern

You need two things:
1. **A bootstrap step** (one-time, manual) — seeds the initial meta-pipeline
2. **A meta-pipeline** — watches the repo and calls `fly set-pipeline` for every pipeline file

The meta-pipeline reconfigures itself too, so once it's bootstrapped, it's self-sustaining.

---

## Directory Layout

```
ci-pipelines/
  pipelines/
    meta.yml          # the meta-pipeline itself
    orders.yml
    payments.yml
    shipping.yml
    ...
  vars/
    prod.yml          # shared pipeline-level vars
  tasks/
    set-pipeline.yml  # reusable task definition
```

---

## Step 1: Bootstrap (one-time, manual)

Run this once. After this, you never need to run `fly set-pipeline` manually again.

```bash
fly -t prod set-pipeline \
  -p meta \
  -c pipelines/meta.yml \
  -l vars/prod.yml

fly -t prod unpause-pipeline -p meta
```

That's it. From here, the meta-pipeline owns everything.

---

## Step 2: The Meta-Pipeline (`pipelines/meta.yml`)

```yaml
---
resource_types: []

resources:
  - name: ci-pipelines-repo
    type: git
    source:
      uri: git@github.com:example/ci-pipelines.git
      branch: main
      private_key: ((github_deploy_key))

  - name: fly-image
    type: registry-image
    source:
      repository: concourse/concourse
      tag: latest

jobs:
  - name: set-meta
    plan:
      - get: ci-pipelines-repo
        trigger: true
      - set_pipeline: self
        file: ci-pipelines-repo/pipelines/meta.yml
        var_files:
          - ci-pipelines-repo/vars/prod.yml

  - name: set-orders
    plan:
      - get: ci-pipelines-repo
        trigger: true
        passed: [set-meta]
      - set_pipeline: orders
        file: ci-pipelines-repo/pipelines/orders.yml
        var_files:
          - ci-pipelines-repo/vars/prod.yml

  - name: set-payments
    plan:
      - get: ci-pipelines-repo
        trigger: true
        passed: [set-meta]
      - set_pipeline: payments
        file: ci-pipelines-repo/pipelines/payments.yml
        var_files:
          - ci-pipelines-repo/vars/prod.yml

  - name: set-shipping
    plan:
      - get: ci-pipelines-repo
        trigger: true
        passed: [set-meta]
      - set_pipeline: shipping
        file: ci-pipelines-repo/pipelines/shipping.yml
        var_files:
          - ci-pipelines-repo/vars/prod.yml

  # add more set-<name> jobs for each pipeline in pipelines/
```

---

## Key Design Decisions

### `set_pipeline` step (native, Concourse 6.5+)

The `set_pipeline` step is a first-class Concourse construct — no `fly` CLI, no credentials mounted into a task container. It runs with the same Concourse worker identity that owns the job. Prefer this over running `fly set-pipeline` inside a task.

```yaml
- set_pipeline: orders
  file: ci-pipelines-repo/pipelines/orders.yml
  var_files:
    - ci-pipelines-repo/vars/prod.yml
```

This also **automatically unpauses** newly created pipelines (Concourse 7.x behavior). On 6.x you may need an explicit `unpause_pipeline` step — see the note below.

### Self-referential `set-meta` job

The `set-meta` job uses `set_pipeline: self`. When `meta.yml` changes on `main`, the first thing that runs is the meta-pipeline reconfiguring itself. All downstream `set-<name>` jobs use `passed: [set-meta]`, so they only run after the meta-pipeline is up to date.

### `trigger: true` on the git resource

Every job triggers on any push to `main`. Concourse fans out — all pipelines get reconfigured on each push. This is intentional: it keeps all pipelines in sync and is idempotent (applying the same config is a no-op).

If you only want to reconfigure a pipeline when its own file changes, you can use `paths:` filtering on the git resource — but then you need one git resource per pipeline, which adds complexity. For 12 pipelines, the fan-out approach is simpler.

---

## Handling the Unpause Problem

On Concourse 7.x, `set_pipeline` on an existing paused pipeline does **not** automatically unpause it. To ensure pipelines are always unpaused after reconfiguration, add an `unpause_pipeline` step:

```yaml
  - name: set-orders
    plan:
      - get: ci-pipelines-repo
        trigger: true
        passed: [set-meta]
      - set_pipeline: orders
        file: ci-pipelines-repo/pipelines/orders.yml
        var_files:
          - ci-pipelines-repo/vars/prod.yml
      - unpause_pipeline: orders
```

> `unpause_pipeline` is available as a native step in Concourse 7.11+. For older versions, you need a task that runs `fly unpause-pipeline`.

---

## Secrets

The git resource needs a deploy key to clone a private repo. Store it as a Concourse credential:

```yaml
private_key: ((github_deploy_key))
```

Add the SSH private key to your credential store (Vault, CredHub, or Concourse's built-in secrets manager). The name `github_deploy_key` matches the `(( ))` interpolation above.

---

## Scaling to More Pipelines

When you add a new pipeline `pipelines/invoicing.yml`, you add one job to `meta.yml`:

```yaml
  - name: set-invoicing
    plan:
      - get: ci-pipelines-repo
        trigger: true
        passed: [set-meta]
      - set_pipeline: invoicing
        file: ci-pipelines-repo/pipelines/invoicing.yml
        var_files:
          - ci-pipelines-repo/vars/prod.yml
      - unpause_pipeline: invoicing
```

Merge that change. The meta-pipeline sees the commit, reconfigures itself, and the new `set-invoicing` job appears automatically.

---

## What This Eliminates

| Before | After |
|--------|-------|
| Manual `fly set-pipeline` after every merge | Automated — runs on every push to `main` |
| Forgetting `fly unpause-pipeline` | `unpause_pipeline` step in meta job |
| Stale config running for weeks | Max lag = Concourse check interval (default 1 min) |
| "Who last ran fly for payments?" | Git history is the audit trail |

---

## Concourse Version Notes

- `set_pipeline` step: Concourse 6.5.0+
- `set_pipeline: self`: Concourse 6.5.0+
- `unpause_pipeline` step: Concourse 7.11.0+
- For Concourse < 7.11, replace `unpause_pipeline` with a task that runs `fly login && fly unpause-pipeline`
