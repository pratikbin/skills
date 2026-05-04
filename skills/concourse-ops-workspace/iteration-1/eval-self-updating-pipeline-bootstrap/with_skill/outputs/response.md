# Self-Updating Concourse Pipelines: Bootstrap Pattern

The core idea is simple: each pipeline contains a `reconfigure-self` job that watches the `ci-pipelines` repo and re-applies its own config whenever `pipelines/<name>.yml` changes on `main`. No human runs `fly set-pipeline`. No one forgets to unpause.

---

## How it works

1. Every pipeline has a `ci` git resource pointing at `main` of `ci-pipelines`.
2. A `reconfigure-self` job triggers on any change to that resource.
3. The job runs `set_pipeline: self`, passing your `vars/prod.yml`.
4. `set_pipeline: self` always unpauses the pipeline automatically — the unpause step people kept forgetting is built in.

The first time (bootstrap), you run `fly set-pipeline` once to upload the pipeline. After that, every subsequent change is handled by the pipeline itself.

---

## Bootstrap: run once per pipeline

```bash
# First-time only — installs the self-managing pipeline
fly -t prod set-pipeline \
  -p orders \
  -c pipelines/orders.yml \
  -l vars/prod.yml

# Unpause so the reconfigure-self job can trigger
fly -t prod unpause-pipeline -p orders
```

After this, you never manually run `fly set-pipeline` for `orders` again.

---

## Pipeline template: `pipelines/orders.yml`

Every one of your 12 pipelines follows this structure. The only thing that changes between them is the pipeline-specific jobs below the `reconfigure-self` job.

```yaml
---
# pipelines/orders.yml
#
# Self-updating pipeline: the reconfigure-self job keeps this pipeline
# in sync with main. Bootstrap once with fly set-pipeline, then let it run.

resources:
  - name: ci
    type: git
    source:
      uri: git@github.com:example/ci-pipelines.git
      branch: main
      private_key: ((github_deploy_key))
      # Narrow the trigger to this pipeline's file and shared vars only.
      # Removes noise from changes to other pipelines.
      paths:
        - pipelines/orders.yml
        - vars/prod.yml

jobs:
  - name: reconfigure-self
    # Run reconfigure serially. If two commits land fast, the second
    # waits rather than creating a race on set_pipeline.
    serial: true
    plan:
      - get: ci
        trigger: true
      - set_pipeline: self
        file: ci/pipelines/orders.yml
        var_files:
          - ci/vars/prod.yml

  # ── Your pipeline's real jobs below ──────────────────────────────────

  - name: test
    plan:
      - get: ci
        passed: [reconfigure-self]
      # ... your actual build steps

  - name: deploy
    plan:
      - get: ci
        passed: [test]
        trigger: true
      # ... your actual deploy steps
```

---

## The `paths:` filter

The `paths:` field on the `ci` resource scopes the git trigger to only the files that affect this specific pipeline. Without it, every commit to any pipeline in the repo would trigger every pipeline's `reconfigure-self` — noisy and wasteful.

```yaml
paths:
  - pipelines/orders.yml
  - vars/prod.yml
```

If you have per-pipeline var files (e.g., `vars/orders.yml`), add those here too.

---

## Scaling to all 12 pipelines

Each pipeline gets its own copy of the above template with two things changed:

1. The `paths:` filter — `pipelines/<name>.yml` instead of `pipelines/orders.yml`.
2. The pipeline-specific jobs.

To bootstrap all 12 at once:

```bash
#!/usr/bin/env bash
# run-once bootstrap script — not needed after this
set -euo pipefail

PIPELINES=(orders payments shipping inventory returns notifications
           fulfillment pricing catalog search recommendations reports)

for name in "${PIPELINES[@]}"; do
  echo "Bootstrapping: $name"
  fly -t prod set-pipeline \
    -p "$name" \
    -c "pipelines/${name}.yml" \
    -l vars/prod.yml \
    -y  # non-interactive, skip diff prompt

  fly -t prod unpause-pipeline -p "$name"
done

echo "Done. All pipelines are now self-managing."
```

Run this once. After that, merging to `main` is the only operation needed to update any pipeline.

---

## Why `set_pipeline: self` handles unpause

Concourse's `set_pipeline: self` step reconfigures the pipeline and automatically unpauses it. This is why the pattern eliminates the "forgot to unpause" incident — there is no separate unpause step to forget.

From the Concourse docs: a pipeline set via `set_pipeline` is left unpaused. The old workflow required a separate `fly unpause-pipeline` call because `fly set-pipeline` by itself does not unpause. The in-pipeline `set_pipeline` step does not have this limitation.

---

## Operational notes

**Viewing the meta-job in the UI**: The `reconfigure-self` job appears as the first box in the pipeline graph. A green build means the live config matches the repo. A red build means the update failed (bad YAML, missing var, auth error) — you still have the old config running, which is safe. Fix the YAML, push again, it retries.

**Deploy keys**: The `private_key: ((github_deploy_key))` var should be stored in your credential manager (Vault, AWS SSM, etc.). This is a read-only deploy key for the `ci-pipelines` repo.

**If a pipeline's `reconfigure-self` job is paused or stuck**: You can still manually push an update with `fly set-pipeline`. The meta-job pattern is not all-or-nothing — manual `fly` commands always work as an escape hatch.

**Adding a new pipeline**: Write `pipelines/newpipe.yml`, merge to `main`, then run the bootstrap one-liner for just that pipeline:

```bash
fly -t prod set-pipeline -p newpipe -c pipelines/newpipe.yml -l vars/prod.yml -y
fly -t prod unpause-pipeline -p newpipe
```

After that, `newpipe` manages itself.
