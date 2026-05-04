# passed-chains.md — passed: constraints, triggers, fan-in, version skew

`passed:` is the scheduler. It tells Concourse which version of a resource to use — only the versions that have survived a named list of jobs. Combined with `trigger: true`, it chains stages. Without `trigger: true`, it constrains without triggering.

## Concepts

### `passed:` as constraint

```yaml
- get: artifact
  passed: [unit, integration]   # only fetch versions that passed both unit AND integration
```

This does NOT trigger the job. It only narrows which version is eligible. The job will not run automatically when a new eligible version appears; it waits for a manual trigger or another `trigger: true` get.

### `trigger: true` as trigger

```yaml
- get: source
  trigger: true                 # a new version of source triggers this job
  passed: [unit]                # but only versions that passed unit
```

This BOTH restricts the eligible version AND schedules the job automatically when a new eligible version appears.

### The combination

A get with both `passed:` and `trigger: true` means: "watch for new versions of this resource that have made it through these jobs; when one appears, run me."

## Worked example: unit → integration → deploy chain

```yaml
resources:
  - name: source
    type: git
    source:
      uri: https://github.com/myorg/app
      branch: main

  - name: artifact
    type: s3
    source:
      bucket: builds
      regexp: app-(.*).tar.gz

jobs:
  - name: unit
    plan:
      - get: source
        trigger: true            # every new commit triggers unit
      - task: test
        file: source/ci/unit.yml
      - put: artifact
        params: { file: compiled/app-*.tar.gz }

  - name: integration
    plan:
      - in_parallel:
          - get: artifact
            trigger: true
            passed: [unit]       # only artifact versions built by unit
          - get: source
            passed: [unit]       # matching source version (same commit)
      - task: integration-test
        file: source/ci/integration.yml

  - name: deploy
    plan:
      - in_parallel:
          - get: artifact
            trigger: true
            passed: [unit, integration]    # must pass both
          - get: source
            passed: [unit, integration]    # matching source; no extra trigger
      - task: deploy
        file: source/ci/deploy.yml
```

Key points:
- `unit` triggers on any new commit. Produces a versioned artifact.
- `integration` triggers on artifact versions that passed `unit`. Gets matching `source`.
- `deploy` triggers on artifact versions that passed **both** `unit` and `integration`. Only `artifact` has `trigger: true`; `source` constrains without triggering.

## Multi-parent fan-in: `passed:` must list all parents

When the same resource must survive multiple independent jobs, list **all** parents in `passed:` on every get that should be version-consistent.

```yaml
jobs:
  - name: security-scan
    plan:
      - get: source
        trigger: true
      - task: scan
        file: ci/scan.yml

  - name: unit
    plan:
      - get: source
        trigger: true
      - task: test
        file: ci/unit.yml

  - name: deploy
    plan:
      - get: source
        trigger: true
        passed: [unit, security-scan]    # must pass BOTH — not just one
      - task: deploy
        file: ci/deploy.yml
```

If you only put `passed: [unit]` on the deploy job's get, `deploy` could use a `source` version that failed `security-scan`.

## Rebuild-without-double-run pattern

When a deploy job depends on multiple independent upstream jobs, naively putting `trigger: true` on all gets causes the deploy to run once per upstream finish:

```yaml
# WRONG — triggers twice when both unit and security-scan finish
- get: source
  trigger: true
  passed: [unit, security-scan]
- get: artifact
  trigger: true
  passed: [unit]
```

Fix: put `trigger: true` on exactly **one** get — usually the artifact or the primary output. All other gets constrain without triggering.

```yaml
# CORRECT — triggers once when the primary artifact is ready; source is a constraint only
- get: artifact
  trigger: true
  passed: [unit, security-scan]
- get: source
  passed: [unit, security-scan]    # no trigger: true
```

Now when `unit` and `security-scan` both complete for commit X, `artifact` gets one new eligible version, triggering `deploy` exactly once.

## Version skew problem

If two resources from the same commit pass separately through the chain, and you list `passed:` only on one of them, you can end up deploying mismatched versions:

```yaml
# WRONG — source might be from a different commit than artifact
- get: artifact
  trigger: true
  passed: [unit]
- get: source          # no passed: — gets latest, not the one that built artifact
```

Fix: always mirror `passed:` on all gets that must be version-consistent:

```yaml
# CORRECT — both come from the same build
- get: artifact
  trigger: true
  passed: [unit]
- get: source
  passed: [unit]       # same constraint; Concourse picks matching version
```

## Gotchas

- `passed:` with a job that doesn't have a `put` for the resource in question will never have eligible versions. The get will block indefinitely. Verify the upstream job actually produces the resource via `put`.
- First run of a new pipeline: no existing builds mean no passed versions. Manually trigger upstream jobs once to seed the version history.
- `trigger: true` on a get with `passed:` still respects the passed constraint. The job does not run on versions that haven't passed the listed jobs.
- Version skew is silent — Concourse doesn't warn you. The wrong version is fetched without error. Always mirror `passed:` on all gets in a fan-in.
- If two gets in a fan-in have different `passed:` lists and they conflict (no version satisfies both), the job is stuck. Check with `fly watch` or `fly builds`.

## See also

- `references/steps-get-put.md` — `trigger:`, `version:`, `passed:` field schemas
- `references/parallelism-patterns.md` — fan-out at top of plan, in_parallel gets
- `references/anti-patterns.md` — trigger:true on every fan-in get (double-runs)
