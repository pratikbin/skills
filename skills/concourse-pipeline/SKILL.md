---
name: concourse-pipeline
description: >-
  Use whenever the user is authoring, reviewing, or speeding up a Concourse `pipeline.yml` — jobs, plans, steps (`get`/`put`/`task`/`in_parallel`/`do`/`try`/`across`/`load_var`/`set_pipeline`), modifiers and hooks (`timeout`/`attempts`/`tags`/`ensure`/`on_*`), `passed:` chains, `serial`/`serial_groups`/`max_in_flight`, build matrices, fan-out/fan-in, YAML anchors, or anti-patterns. Trigger on phrases like "concourse pipeline yaml", "make this concourse job faster", "parallelize my pipeline", "build matrix in concourse", "across step", "passed: not triggering", "fan-out my gets", "concourse hooks on_failure", "set_pipeline step", "self-updating pipeline", and proactively whenever new pipeline-level concourse YAML is being written. Based on Concourse v8+ docs and concourse/ci real-world pipelines (`concourse.yml`, `release.yml`, `pr.yml`, `reconfigure.yml`).
---

# concourse-pipeline

Practical playbook for **authoring fast, idiomatic Concourse `pipeline.yml`**. Tells you **what to write**, **why it speeds the build**, and **when not to bother**. Targets the schema as of Concourse v8+ — confirm with `fly -t … validate-pipeline -c …` before relying.

## When to use this skill

Activate whenever the work touches a `pipeline.yml` (or the `set_pipeline` step that produces one). Examples:

- "speed up this concourse job"
- "parallelize these gets"
- "the same job keeps running twice"
- "build matrix across versions"
- "what does `passed:` do here"
- "should I use `serial`, `serial_groups`, or `max_in_flight`?"
- "this hook fires when I don't want it to"
- new pipeline being scaffolded for a service

For task-config (`task.yml`, `image_resource`, `caches:`) → `concourse-tasks`. For resource sources (`paths`, `tag_filter`, custom types) → `concourse-resources`. For `fly`/credentials/teams/perf-tuning → `concourse-ops`.

## Core mental model

1. **A pipeline is `resources` × `jobs`.** Resources represent versioned external state. Jobs are sequences of steps that consume resource versions and may push new ones via `put`.
2. **Steps are typed.** `get`/`put` interact with resources. `task` runs a pure function in a container. `in_parallel`/`do`/`try`/`across` compose other steps. `load_var`/`set_pipeline` are meta steps (build-time discovery / pipeline-as-code).
3. **`passed:` is the scheduler.** A `get` with `passed: [job-a, job-b]` only sees versions that have made it through both jobs. Combined with `trigger: true`, this is how stages chain. Without `trigger: true`, the get is a *constraint*, not a *trigger*.
4. **Parallelism comes from three places, in order of payoff.** (a) `in_parallel` on the gets at the top of the plan, (b) `in_parallel` on independent task shards, (c) `across:` for build matrices. Sequential gets are the single most common reason a pipeline feels slow.
5. **Concurrency comes from `max_in_flight` (per job) and `serial`/`serial_groups` (across jobs).** Default is unlimited per job, no serialization between jobs. Tighten only when you're protecting shared external state.

## Decision tree — pick the right reference

Match the symptom or question to a reference, then read that file for schema, examples, and gotchas.

```
Symptom / question                                     → Read first
─────────────────────────────────────────────────────────────────────────────
"what are the top-level keys?"                         → references/schema.md
"job is taking forever / 4 sequential gets"            → references/parallelism-patterns.md
                                                         + references/steps-flow.md
"I want a build matrix across versions/OSes"           → references/parallelism-patterns.md
                                                         + references/steps-flow.md (across)
"`across` complains about my `get`/`put` step"         → references/steps-flow.md (across caveats)
"same job runs twice when both upstream jobs finish"   → references/passed-chains.md
"`passed:` set but job never triggers"                 → references/passed-chains.md
                                                         + references/steps-get-put.md (trigger)
"two jobs deploy to staging — they collide"            → references/jobs.md (serial_groups)
"throttle parallel runs of one job"                    → references/jobs.md (max_in_flight, serial)
"task step config — params vs vars vs file"            → references/steps-task.md
"task step image / image_resource"                     → references/steps-task.md
                                                         + concourse-tasks skill (image_resource)
"on_failure / on_success / ensure / on_abort"          → references/modifiers-hooks.md
"timeout / attempts / tags on a step"                  → references/modifiers-hooks.md
"build-time variable from a file"                      → references/steps-meta.md (load_var)
"pipeline that updates itself"                         → references/steps-meta.md (set_pipeline)
                                                         + concourse-ops skill (instance pipelines)
"DRY my pipeline — too much repetition"                → references/yaml-anchors.md
"smell test — what am I doing wrong?"                  → references/anti-patterns.md
```

## Fast defaults (copy-paste-ready)

These bias toward speed. Read the linked reference before changing the values.

### Fan out the first stage of every job

Sequential gets are the #1 speed killer. Wrap the gets at the top of the plan in `in_parallel`. See `references/parallelism-patterns.md`.

```yaml
- in_parallel:
    fail_fast: true        # bail as soon as one input fails — don't waste worker time
    limit: 4               # cap concurrency if you have many gets and few workers
    steps:
      - get: source
        trigger: true
      - get: ci
      - get: deps-image
      - get: version
```

### Build matrix without re-fetching

`across:` runs the body once per combination of var values. Get the inputs **once** outside `across:`; reference them inside. `across:` does **not** support `get`/`put` directly. See `references/steps-flow.md`.

```yaml
- get: source
- across:
    - var: go_version
      values: ["1.22", "1.23", "1.24"]
    - var: os
      values: ["linux", "darwin"]
  max_in_flight: all       # run all combinations in parallel
  fail_fast: true
  do:
    - task: test
      file: source/ci/test.yml
      vars: { go: ((.:go_version)), os: ((.:os)) }
```

### Stage chains that don't double-trigger

When a job depends on the **same** upstream version surviving multiple parents, list **all** parents in `passed:` and put `trigger: true` on **one** get. The others should constrain without triggering. See `references/passed-chains.md`.

```yaml
- get: artifact
  trigger: true
  passed: [unit, integration, acceptance]   # version must pass all three
- get: source
  passed: [unit, integration, acceptance]
```

### Hooks that don't block the happy path

Use `on_*` hooks for side effects (alerts, cleanup) and `ensure` only when the cleanup must run on every outcome including abort. Hooks share the parent step's containers; expensive cleanup tasks should be flagged `interruptible`. See `references/modifiers-hooks.md`.

```yaml
- task: deploy
  file: ci/tasks/deploy.yml
  on_failure:
    task: notify-slack
    file: ci/tasks/slack.yml
  on_abort:
    task: rollback
    file: ci/tasks/rollback.yml
  ensure:
    task: cleanup-workspace
    file: ci/tasks/cleanup.yml
```

## When NOT to optimize

- **One-shot debug pipelines.** Just write it sequentially; clarity beats speed.
- **A pipeline that already finishes faster than the resource check interval.** No user-perceived gain; just adds risk of cross-step coupling bugs.
- **`across:` for two values.** Two parallel jobs are clearer than a matrix.
- **YAML anchors when the duplication is two lines.** Anchors win when a block repeats 3+ times or carries a meaningful name.

## Anti-pattern flags

If reviewing an existing pipeline, scan first for these. See `references/anti-patterns.md` for full list.

- Plan starts with N sequential gets and no `in_parallel`.
- Multi-parent fan-in with `passed:` only on one get → version skew.
- `serial: true` on a job that doesn't actually share external state — kills throughput for no reason.
- `trigger: true` on every get in a fan-in stage → job runs N times when one upstream commit lands.
- Hooks (`on_failure`) doing real work without a `timeout` — they will hang the build.
- `across:` wrapping a `get` step (silently ignored or produces a confusing error).
- `set_pipeline` step inside a job that also runs tests — split it; deploy-of-pipeline shouldn't depend on test outcome unless that's deliberate.

## Cross-references

- `concourse-resources` — when the question is about a resource type, version filtering, or `paths`/`ignore_paths`/`check_every`.
- `concourse-tasks` — when the question is about task config, `image_resource`, `caches:`, or `oci-build-task`.
- `concourse-ops` — `fly` CLI, vars/var_sources, credential managers, instance pipelines, performance tuning at the cluster level.
