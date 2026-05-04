# Why `deploy-staging` Runs Twice (and How to Fix It)

## Root Cause

Your pipeline has `trigger: true` on **two separate gets** inside the same `in_parallel` block:

```yaml
- in_parallel:
    - get: app-image
      trigger: true
      passed: [unit]
    - get: source
      trigger: true
      passed: [integration]
```

Concourse evaluates each `get` with `trigger: true` independently. When `unit` finishes, `app-image` has a new eligible version — that's one trigger. When `integration` finishes, `source` has a new eligible version — that's a second trigger. The result: `deploy-staging` fires once per upstream job completion, so two upstream jobs means two runs. If one of them retries due to flake, you get a third.

This is the classic **fan-in double-trigger anti-pattern**: N gets with `trigger: true` in a fan-in stage produces up to N runs per commit.

---

## The Fix

Put `trigger: true` on exactly **one** get — the one whose new eligible version signals "all upstream work is done." Remove `trigger: true` from all other gets; they still constrain the version but don't independently fire the job.

```yaml
  - name: deploy-staging
    plan:
      - in_parallel:
          - get: app-image
            trigger: true
            passed: [unit, integration]   # must pass BOTH upstream jobs
          - get: source
            passed: [unit, integration]   # same constraint, no independent trigger
      - task: deploy
        file: source/ci/deploy.yml
```

With this change:

- `deploy-staging` only fires when `app-image` has a version that has cleared **both** `unit` and `integration`.
- `source` is fetched at the matching version (version skew prevention — see below), but does not independently trigger a run.
- The job still triggers automatically on every successful main commit — you haven't lost that behavior.

---

## Why Both `passed:` Lists Must Match

Notice the corrected YAML puts `passed: [unit, integration]` on **both** gets, not just `app-image`. This is important.

If you only constrain `app-image` and leave `source` unconstrained (or constrained to a different set of jobs), Concourse will fetch the latest `source` independently — which could be from a **different commit** than the one that produced `app-image`. Your deploy task would then run with a mismatched image and source tree. Concourse does not warn you about this; it silently fetches the wrong version.

Always mirror `passed:` on every get in a fan-in stage that needs to be version-consistent.

---

## Version Skew Note for Your Specific Pipeline

Your original config had a split `passed:` structure:

- `app-image` passed only through `unit`
- `source` passed only through `integration`

These are separate resource lineages. Depending on how your pipeline is wired, this could mean `app-image` and `source` were never guaranteed to be from the same commit at all. The corrected version enforces that both resources have cleared the same set of upstream jobs before deploy proceeds.

If `unit` produces `app-image` and `integration` consumes it, you likely want the canonical pattern from the Concourse docs:

```yaml
# Upstream jobs each produce/consume a shared artifact that ties the version lineage together.
# deploy-staging then gates on that artifact passing both jobs.

  - name: deploy-staging
    plan:
      - in_parallel:
          - get: app-image
            trigger: true
            passed: [unit, integration]
          - get: source
            passed: [unit, integration]
      - task: deploy
        file: source/ci/deploy.yml
```

This ensures the scheduler has a single version "spine" to track, eliminating both the double-trigger and any version skew between image and source.
