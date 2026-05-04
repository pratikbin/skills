# Instance pipelines

Instanced pipelines are multiple pipelines sharing the same template, differentiated by a set of key-value "instance vars". Concourse groups them visually and logically.

## Concept

A pipeline instance is identified by its name plus a map of instance vars. `feature-pipeline/branch:main` and `feature-pipeline/branch:feat-x` are two instances of the same pipeline group.

Instance vars are set at `fly set-pipeline` time (via `-i`) or in a `set_pipeline` step (via `instance_vars:`).

## Creating instances

### Via fly CLI

```bash
# create or update an instance
fly -t prod set-pipeline -p feature-pipeline -c pipeline.yml \
    -i branch=main

# second instance, same template
fly -t prod set-pipeline -p feature-pipeline -c pipeline.yml \
    -i branch=feat-x \
    -l vars/feat-x.yml

# view all instances in the group
fly -t prod pipelines
```

### Via set_pipeline step

```yaml
jobs:
  - name: sync-branch-pipelines
    plan:
      - get: repo
        trigger: true
      - set_pipeline: feature-pipeline
        file: repo/ci/branch-pipeline.yml
        instance_vars:
          branch: ((.:git_branch))
        vars:
          slack_channel: "#builds"
```

`((.:git_branch))` reads a local build var (e.g. set by `load_var` or across step). Instance vars become part of the pipeline identity.

## Branch-per-pipeline pattern

```yaml
resources:
  - name: repo
    type: git
    source:
      uri: https://github.com/myorg/app.git
      branches: "feature/.*"     # requires git resource v1.14+

jobs:
  - name: manage-instances
    plan:
      - get: repo
        trigger: true
      - load_var: branch-name
        file: repo/.git/ref
      - set_pipeline: app
        file: repo/ci/pipeline.yml
        instance_vars:
          branch: ((.:branch-name))
```

Each new branch gets its own pipeline instance. Merging/deleting a branch does not auto-archive; add a cleanup job.

## Ordering instances

```bash
# reorder within an instance group (dashboard ordering)
fly -t prod order-instanced-pipelines -p feature-pipeline \
    -i branch=main -i branch=feat-x -i branch=bugfix-y
```

`order-instanced-pipelines` only accepts instance var sets in the order you want. Instances not listed are moved to the end.

## Archival

Archiving one instance does not affect others:

```bash
fly -t prod archive-pipeline -p feature-pipeline -i branch=feat-x
```

The instance disappears from active scheduling but remains visible on the dashboard as "archived". Config is deleted; `fly get-pipeline` will error.

## Gotchas

- Instance vars must be strings. Numbers and booleans must be quoted: `-i version=8`, not `-i version:8`.
- You cannot mix instanced and non-instanced pipelines with the same name. Attempting to set `feature-pipeline` without `-i` when instances exist will error.
- Instance vars are visible in the pipeline URL and dashboard. Do not use them for secrets.
- `fly order-pipelines` orders pipeline groups, not instances within a group. Use `fly order-instanced-pipelines` for within-group ordering.

## See also

- `references/set-pipeline-step.md` — `instance_vars:` on `set_pipeline` step
- `references/fly-cli.md` — `-i` flag on `fly set-pipeline`, `fly order-instanced-pipelines`
- `references/vars-and-var-sources.md` — local build vars with `load_var`
