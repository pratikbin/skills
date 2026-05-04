---
name: concourse-ops
description: Use whenever the user is operating, debugging, or scaling a Concourse cluster — `fly` CLI (login, set-pipeline, intercept, execute, prune-worker, check-resource), self-updating pipelines via `set_pipeline` step, instance pipelines, vars / `var_sources`, credential managers (Vault, AWS Secrets Manager / SSM, CredHub, Kubernetes, IDToken/OIDC), team and auth setup (`fly set-team`, GitHub/OIDC/SAML/LDAP), performance tuning (`CONCOURSE_*` env vars), container placement strategies, OPA policy, metrics + tracing, "stuck job" / "stuck check" debugging, "credential cache". Trigger on phrases like "fly login", "fly set-pipeline", "fly intercept", "self-update pipeline", "instance pipeline", "vault var_source", "aws secrets manager", "concourse teams", "github auth concourse", "concourse perf tuning", "container placement", "stuck check", "stuck build", "prune worker", "concourse metrics", "concourse OPA". Based on Concourse v8+ docs (operation/*, creds/*, fly, auth-and-teams).
---

# concourse-ops

Practical playbook for **operating, debugging, and scaling Concourse clusters** — the parts that live outside `pipeline.yml` but make pipelines actually work. Tells you **which `fly` knob to reach for**, **which credential manager fits**, and **what env var changes when**. Targets Concourse v8+ — confirm flag spellings with `fly --help` and the docs version your cluster runs.

## When to use this skill

Activate whenever the work touches `fly`, `var_sources`, credentials, teams, the cluster's env vars, instance pipelines, observability, or any "why is this stuck" question. Examples:

- "fly set-pipeline failing with auth error"
- "set up a vault var source for our team"
- "should we use IDToken / OIDC federation instead of static AWS keys"
- "this build is stuck — what do I try"
- "stuck check on resource X"
- "rotate credentials without redeploying every pipeline"
- "self-update pipeline pattern"
- "branch-per-pipeline / PR-per-pipeline"
- "concourse cluster feels slow"
- "container placement strategies"
- "GitHub auth for our team"
- "how do I prune a worker that disappeared"

For pipeline-level structure (jobs, plans, steps) → `concourse-pipeline`. For resource sources/types → `concourse-resources`. For task config (`task.yml`, image_resource, caches) → `concourse-tasks`.

## Core mental model

1. **Pipelines are state, `fly` is the verb.** `fly` is the only supported way to mutate a cluster's pipelines, teams, workers, and live-running builds. Anything you'd click in the UI you can do with `fly`; anything `fly` can do you can also bind to a `set_pipeline` step inside a pipeline (pipeline-as-code).
2. **`var_sources` is how `((vars))` get resolved.** Cluster-level (env vars on the web node) and team-level (`var_sources:` block in a pipeline) sources both work. The `((path.key))` syntax means "look up `path` in the var source named `path`'s prefix" or, with no prefix, "use the default cluster source".
3. **The `set_pipeline` step is the keystone of self-managing Concourse.** A "meta-pipeline" can `set_pipeline` other pipelines (or itself, with `set_pipeline: self`). Combined with instance pipelines (`instance_vars:`), one definition can produce N pipelines (e.g. one per branch).
4. **Most "Concourse is slow" issues are operator-side, not pipeline-side.** Default check intervals, default container placement strategy, and missing global resources are the usual suspects. Tuning is mostly env vars on the web node and worker placement strategy chains.
5. **Debugging is `fly intercept`-first.** Failed builds keep their containers. `fly intercept` drops you into the exact rootfs the step ran in, with the exact env. Most "this works on my laptop" mysteries close in 60 seconds with `fly intercept`.

## Decision tree — pick the right reference

Match the symptom or question to a reference, then read that file for full schema, examples, and gotchas.

```
Symptom / question                                            → Read first
─────────────────────────────────────────────────────────────────────────────────
"fly command — login, target, set-pipeline, get-pipeline,…"   → references/fly-cli.md
"set_pipeline step (in-pipeline pipeline-as-code)"            → references/set-pipeline-step.md
                                                                + concourse-pipeline (steps-meta.md)
"branch-per-pipeline / PR-per-pipeline"                       → references/instance-pipelines.md
                                                                + references/set-pipeline-step.md
"how does ((var)) get resolved? schema for var_sources"       → references/vars-and-var-sources.md
"set up Vault as a credential manager"                        → references/creds-vault.md
"AWS Secrets Manager / SSM Parameter Store"                   → references/creds-aws.md
"Kubernetes secrets as credentials"                           → references/creds-k8s.md
"CredHub credential manager"                                  → references/creds-credhub.md
"OIDC / IDToken federation to AWS / GCP / Azure (no statics)" → references/creds-id-token.md
"redact secrets in build output / cache credentials"          → references/creds-caching-redacting.md
"set up team / GitHub or OIDC auth / role permissions"        → references/teams-auth.md
"Concourse cluster is slow / scaling / postgres"              → references/perf-tuning.md
"fewest-build-containers / volume-locality / random / chains" → references/container-placement.md
"global resources — dedup checks across pipelines"            → references/global-resources.md
                                                                + concourse-resources/global-resources.md
"metrics / tracing / Prom / Datadog / Jaeger / cc.xml"        → references/observability.md
"OPA policy decisions for set_pipeline / put / etc."          → references/opa.md
"build is stuck / check is stuck / worker dropped / unstuck"  → references/debugging-stuck.md
"smell test for ops setup?"                                   → (none — see other refs' Gotchas)
```

## Fast defaults (copy-paste-ready)

These bias toward security, scalability, and zero-credential-rotation. Read the linked reference before tweaking.

### Self-updating pipeline (no manual `fly set-pipeline` after first run)

A "meta" job uses the `set_pipeline` step to keep the pipeline in sync with the repo. Bootstrap manually once; everything after is automatic. See `references/set-pipeline-step.md`.

```yaml
# pipeline.yml — set itself
jobs:
  - name: reconfigure-self
    plan:
      - get: ci
        trigger: true
      - set_pipeline: self        # update THIS pipeline from the same repo
        file: ci/pipeline.yml
        var_files: [ci/vars/prod.yml]
```

### Vault var_source (team-scoped)

Resolve `((vault_team:my-secret.password))` from a team-scoped Vault. See `references/creds-vault.md`.

```yaml
var_sources:
  - name: vault_team
    type: vault
    config:
      url: https://vault.example.internal
      auth_backend: approle
      auth_params:
        role_id: ((bootstrap_role_id))
        secret_id: ((bootstrap_secret_id))
      path_prefix: /concourse/team-name
```

### IDToken (OIDC federation) — no static AWS keys

Concourse mints a JWT per build; AWS / GCP / Azure trust it via federation. No static credentials in Vault or env vars. See `references/creds-id-token.md`.

```yaml
var_sources:
  - name: aws
    type: idtoken
    config:
      audiences: [sts.amazonaws.com]
# Then use ((aws:my-aws-role)) to fetch credentials minted from a federated AssumeRole
```

### Container placement that respects volume locality

Default placement is `volume-locality` + `fewest-build-containers`. Most "task fetch is slow" reports come from random placement defeating volume reuse. See `references/container-placement.md`.

```properties
# web node env
CONCOURSE_CONTAINER_PLACEMENT_STRATEGY=volume-locality,fewest-build-containers
CONCOURSE_LIMIT_ACTIVE_CONTAINERS=250   # if a chained limit fits the cluster
```

### Stuck check or stuck build first-aid

`fly intercept` for stuck builds; `fly check-resource` to force a re-check. See `references/debugging-stuck.md`.

```bash
# stuck build — interactively dive in
fly -t prod intercept -j my-pipeline/my-job -s build-step

# stuck check — force re-check
fly -t prod check-resource -r my-pipeline/my-resource

# worker disappeared from "fly workers"
fly -t prod prune-worker -w worker-name
```

## When NOT to optimize

- **A 5-pipeline cluster.** Default tuning is fine. Skip global resources, custom placement, and OPA until you actually feel the pain.
- **Static credentials when nobody's actually rotating them anyway.** IDToken/OIDC is much better, but only if your team will actually configure the trust on the cloud side.
- **Self-updating pipelines for ad-hoc work.** Manual `fly set-pipeline` is fine for prototypes; pipeline-as-code matters once 2+ humans touch the same pipeline.

## Anti-pattern flags

If reviewing an existing operator setup, scan first for these.

- Static cloud credentials (AWS keys, GCP SA JSON) in Vault when the cluster could use IDToken/OIDC.
- `CONCOURSE_SECRET_CACHE_ENABLED=false` (or unset) in clusters with thousands of resource checks/min — burns the credential server.
- Default `CONCOURSE_CONTAINER_PLACEMENT_STRATEGY=random` on a cluster with persistent volumes; defeats volume locality.
- Missing redact (very old clusters) — secrets show up in build logs.
- One huge `main` team with 30 humans and 200 pipelines instead of 5 teams of 6 with their own pipelines and vars.
- `fly set-pipeline` from a developer laptop instead of an automated `set_pipeline` step.
- No metrics emitter configured — debugging slow clusters by hand instead of looking at lidar/scheduler/build durations.
- `privileged: true` on resource_types/tasks that don't need it (most don't).
- `CONCOURSE_MAIN_TEAM_*` left as the default "every authenticated user is owner".

## Cross-references

- `concourse-pipeline` — the `set_pipeline` step itself, hooks, `passed:` and `serial`/`max_in_flight` (job-level concurrency vs cluster-level placement).
- `concourse-resources` — `global_resources` from the resource-author angle, `webhook_token` to cut polling load.
- `concourse-tasks` — `fly execute` for local task iteration, `fly intercept` deep-dives, `caches:` semantics.
