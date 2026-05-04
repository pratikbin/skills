# Concourse Double-Trigger: Root Cause and Fix

## Why It's Firing Twice

The problem is how Concourse evaluates `trigger: true` with `passed` constraints in an `in_parallel` block.

When a new commit lands on `main`, both `unit` and `integration` run. Each produces a new version of its output resources. Concourse tracks resource versions independently. When `unit` finishes, it creates a new version of `app-image` (or advances it through the `passed` filter). When `integration` finishes, it creates a new version of `source` that has passed `integration`.

Here's the core behavior: **each `get` with `trigger: true` is evaluated independently.** Concourse will schedule a new build of `deploy-staging` whenever *any* triggered resource gets a new satisfying version — it does not wait for all triggered gets to be satisfied simultaneously.

So the sequence is:

1. `unit` finishes → `app-image` gets a new version passing `[unit]` → Concourse schedules `deploy-staging` run #1.
2. `integration` finishes → `source` gets a new version passing `[integration]` → Concourse schedules `deploy-staging` run #2.
3. Both runs execute with the same SHA.

If one of them is flaky and retries, you get a third run on the same SHA.

This is Concourse's **fan-in problem**. Multiple `trigger: true` resources each independently fire the job when they become available, rather than waiting for all of them to converge.

## The Fix: Remove Redundant Triggers, Use a Single Trigger Point

The correct pattern is to use **only one resource as the trigger**, and use the `passed` constraints on the others purely as gates (without `trigger: true`). The single trigger fires the job; the `passed` constraints ensure the other upstream jobs have already completed for that version before the job can run.

```yaml
  - name: deploy-staging
    plan:
      - in_parallel:
          - get: app-image
            passed: [unit]
          - get: source
            trigger: true
            passed: [integration]
      - task: deploy
        file: source/ci/deploy.yml
```

### How This Works

- `source` with `trigger: true` and `passed: [integration]` fires `deploy-staging` only when `integration` has passed for that version of `source`.
- `app-image` with `passed: [unit]` (no `trigger`) acts as a gate: Concourse will only schedule the build when a version of `app-image` exists that has passed `[unit]`. If `unit` hasn't finished yet, the build is held pending.
- Result: one build fires per commit, and it only runs when **both** upstream jobs have completed successfully for that SHA.

### Which Resource Should Be the Trigger?

Pick whichever resource most directly represents "a new commit is ready to deploy." In most pipelines, `source` (the git resource) is the natural trigger because it represents the commit. `app-image` is a derived artifact — you generally want the source commit to be the scheduling unit.

If `unit` tends to finish after `integration`, you may want to flip the trigger to `app-image` and gate on `source`. The behavior is symmetric — what matters is having exactly **one** trigger.

### Why Not Just Remove All Triggers?

If you remove all `trigger: true` flags, the job becomes manual-only. You'd need to click "trigger" in the UI or use `fly trigger-job`. That breaks the "deploy on every successful main commit" requirement.

### What About Flaky CI?

If a job retries and succeeds, Concourse will see a new passing version and may re-trigger. This is expected behavior for retried jobs. To avoid deploy re-runs on retries, you can pin the trigger resource to only advance on explicit new commits (i.e., ensure your git resource uses `check_every` appropriately and doesn't produce duplicate versions). But the single-trigger pattern eliminates the double-run caused by fan-in; retry-triggered reruns are a separate concern.

## Summary

| Before | After |
|--------|-------|
| Two `trigger: true` → two independent triggers → two builds | One `trigger: true` → one trigger, other is a gate → one build |

The fix is surgical: remove `trigger: true` from `app-image`, keep it on `source`. The `passed` constraint on `app-image` still enforces that `unit` must have passed before the deploy runs.
