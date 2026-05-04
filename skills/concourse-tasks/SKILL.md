---
name: concourse-tasks
description: Use whenever the user is writing or speeding up a Concourse task config (`task.yml`, inline task `config:`), choosing or pinning a task `image_resource`, configuring `caches:` for package managers, building OCI images via `oci-build-task`, debugging a task with `fly intercept`/`fly execute`, or asking why a task is "slow". Trigger on phrases like "task config", "task.yml", "image_resource", "task slow", "build cache", "oci-build-task", "buildkit cache", "package install in CI", "fly execute", "fly intercept", "task params vs vars", "input_mapping", "output_mapping", "container limits", and proactively whenever new task YAML is being written or an existing one is being slimmed down. Based on Concourse v8+ task schema and the official `oci-build-task` README. Speed angle: pinned image_resource, `caches:` for package managers, cache-as-task pattern, oci-build-task buildkit `cache` path, minimal input scope.
---

# concourse-tasks

Practical playbook for **writing fast, debuggable Concourse tasks**. Tells you **what to put in `task.yml` (and what to leave out)**, **why each cache layer wins**, and **when a "fast" task config is actually wrong**. Targets Concourse v8+ task schema — confirm with `fly validate-pipeline` (which validates inline task configs too).

## When to use this skill

Activate whenever the work touches a `task.yml`, a `task` step's inline `config:`, an `image_resource:`, `caches:`, or anything related to the build environment a task runs in. Examples:

- "this task takes 4 minutes installing npm packages every time"
- "Dockerfile build in CI is slow"
- "what should I put in `image_resource`"
- "tag: latest on our builder image — fine?"
- "task ran fine locally with `fly execute` but fails in the pipeline"
- "how do I rename a task input without rewriting task.yml"
- "params vs vars — when do I use which"
- "task got OOM-killed"
- "is my Dockerfile build actually using buildkit cache"

For pipeline-level structure (jobs, plans, steps, parallelism) → `concourse-pipeline`. For resource sources (`paths`, `tag_filter`, custom types) → `concourse-resources`. For `fly`/credentials/teams → `concourse-ops`.

## Core mental model

1. **A task is a pure function: `(inputs, params) → outputs ∪ exit_status`.** Same inputs and same params should always give the same outputs (or always fail). Anything that breaks this — apt-get install in `run`, network calls during the task, hidden state in `~` — also breaks debuggability.
2. **`task.yml` is the function signature; the `task` step in the pipeline is the call site.** Schema: `platform`, `image_resource`, `inputs`, `outputs`, `params` (env), `caches`, `run`, optional `container_limits`, `rootfs_uri`. The pipeline-side `task` step supplies `vars` (interpolation), `image:` override, `params:` overrides, `input_mapping`/`output_mapping` for renames.
3. **Speed comes from three places, in order of bang-for-buck.** (a) `image_resource` is pre-baked with the task's deps so `run` can skip install. (b) `caches:` keep package-manager caches between runs of the same job/step name on the same worker. (c) For Dockerfile builds, `oci-build-task`'s `cache` path keeps buildkit layers between runs.
4. **`caches:` are scoped by worker × job-name × step-name × cache path.** Renaming the job, step, or cache path = cache miss. Caches are not portable between workers — assume the task can run cold. Caches don't exist for one-off `fly execute` builds.
5. **Most "task slow" reports are really "image_resource is wrong" reports.** A task whose image installs `gcc make python3 nodejs npm` in its first 30s of runtime should bake those into the image instead. The image becomes the cache.

## Decision tree — pick the right reference

Match the symptom or question to a reference, then read that file for schema, examples, and gotchas.

```
Symptom / question                                        → Read first
─────────────────────────────────────────────────────────────────────────────
"task.yml schema"                                         → references/schema.md
"why pure-function model matters"                         → references/pure-function-model.md
"image_resource — pin by digest / variants / private"     → references/image-resource.md
                                                            + concourse-resources/registry-image
"how do task inputs and outputs work"                     → references/inputs-outputs.md
                                                            + (Concourse docs: getting-started/inputs-outputs)
"input_mapping / output_mapping — rename without rewrite" → references/inputs-outputs.md
"caches: how do they work / why miss"                     → references/caches.md
"task installs npm/pip/maven every run"                   → references/caches.md
                                                            + references/cache-as-task.md
"shared dependency cache across workers / branches"       → references/cache-as-task.md
"build a Dockerfile in concourse"                         → references/oci-build-task.md
"buildkit cache / multi-platform / secrets in build"      → references/oci-build-task.md
"params vs vars — what's the difference"                  → references/params-vs-vars.md
"run.path / run.args / run.dir / run.user"                → references/run-block.md
"fly execute (run task locally) / fly intercept"          → references/debugging.md
"task got OOM-killed / cpu_limit / memory_limit"          → references/container-limits.md
"smell test — what's wrong with this task config?"        → references/anti-patterns.md
```

## Fast defaults (copy-paste-ready)

These bias toward speed and reproducibility. Read the linked reference before tweaking the values.

### Pin `image_resource` by digest, prebake deps

`tag: latest` is silent breakage waiting to happen. Build a small custom builder image that already has your deps and pin it. See `references/image-resource.md`.

```yaml
# task.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: ghcr.io/example/go-builder
    tag: "1.22"
    # OR pin by digest for full reproducibility:
    # version: { digest: "sha256:abc123..." }

inputs:
  - name: source
outputs:
  - name: bin

run:
  path: bash
  args:
    - -ec
    - |
      cd source
      go build -o ../bin/app ./cmd/app
```

### Cache the package manager directory

Cache hit ⟹ `npm ci` / `go mod download` / `pip install` becomes near-zero. See `references/caches.md`.

```yaml
# task.yml
platform: linux

image_resource:
  type: registry-image
  source: { repository: node, tag: "20-bookworm-slim" }

inputs:
  - name: source
outputs:
  - name: build

caches:
  - path: source/node_modules     # populated on first run, reused after

run:
  path: bash
  args:
    - -ec
    - |
      cd source
      npm ci --prefer-offline
      npm run build
      cp -r dist ../build/
```

### Build a Dockerfile fast (oci-build-task with buildkit cache)

`cache:` keeps buildkit layers between runs on the same worker. See `references/oci-build-task.md`.

```yaml
# task.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: concourse/oci-build-task
    # version: { digest: "sha256:..." }   # pin in production

inputs:
  - name: source

outputs:
  - name: image

caches:
  - path: cache                     # buildkit layer cache

params:
  CONTEXT: source                   # build context dir
  # DOCKERFILE: source/Dockerfile   # default is CONTEXT/Dockerfile

run:
  path: build
```

### Rename inputs at the call site instead of duplicating the task

Two upstreams produce different artifact names but feed the same task — use `input_mapping` instead of writing a second `task.yml`. See `references/inputs-outputs.md`.

```yaml
# pipeline.yml
- task: integration-test
  file: ci/tasks/integration.yml      # task expects input "app-binary"
  input_mapping:
    app-binary: orders-api-bin        # the actual artifact in this job
```

## When NOT to optimize

- **A task that runs once a day and takes 30s.** Caches add complexity for no measurable gain.
- **`fly execute` runs from a developer laptop.** Caches don't apply (no job/step name); just live with the cold start.
- **Tasks that are inherently network-bound (e.g., e2e tests against staging).** Speeding the dep install saves 10s out of a 5min job.
- **Cache-as-task pattern for a project with two dependencies.** The orchestration overhead exceeds the savings.

## Anti-pattern flags

If reviewing an existing task config, scan first for these. See `references/anti-patterns.md` for full list.

- `apt-get install …` or `pip install …` in `run.args` (instead of in the image).
- `image_resource` with `tag: latest` and no digest pin.
- Task outputs unused by any downstream step (waste of artifact-namespace I/O).
- `caches:` paths that change every run (e.g., `caches: { path: build/$BUILDID/cache }`).
- `caches:` on a one-off `fly execute` task — silently does nothing.
- `params:` carrying secrets in plaintext instead of `vars:` with credential interpolation.
- Inline `config:` block when the task is reused — extract to `task.yml` and reference via `file:`.
- `oci-build-task` without `caches: [{path: cache}]` for a Dockerfile that has expensive RUN steps.
- Missing `outputs:` declaration when downstream steps need the artifact.
- `privileged: true` on a task step that doesn't need it (everything except specific Docker-in-Docker/system-test patterns).

## Cross-references

- `concourse-pipeline` — `task` step itself (file vs config, input_mapping, output_mapping at the call site, hooks).
- `concourse-resources` — `registry-image` resource that the `image_resource` references; pinning, semver_constraint, custom resource types.
- `concourse-ops` — vars/var_sources for task `vars:` interpolation, `fly execute`/`fly intercept` deeper coverage, secret managers.
