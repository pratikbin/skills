# schema.md — top-level pipeline.yml keys and minimal valid pipeline

Top-level keys in a Concourse `pipeline.yml`. All are lists. Only `jobs` is required for a valid pipeline; everything else is optional but almost always present.

## Schema

```yaml
# pipeline.yml top-level keys
resources:        # list of resource declarations
resource_types:   # list of custom resource type declarations (optional)
jobs:             # list of job declarations (required)
var_sources:      # list of credential manager configs (optional, v7.8+)
groups:           # list of UI groupings (optional; once added, every job must belong to one)
display:          # pipeline-level UI config (optional)
```

### `resources`

Declares versioned external objects the pipeline interacts with. Each entry needs at minimum `name`, `type`, and usually `source`.

```yaml
resources:
  - name: source
    type: git
    source:
      uri: https://github.com/myorg/myrepo
      branch: main
```

See `concourse-resources` skill for `check_every`, `version` pinning, `tags`, `icon`, `public`, and custom type sources.

### `resource_types`

Extends Concourse with community or internal resource types beyond the built-ins. Each entry needs `name`, `type` (usually `registry-image`), and `source`.

```yaml
resource_types:
  - name: slack-notification
    type: registry-image
    source:
      repository: cfcommunity/slack-notification-resource
      tag: latest
```

See `concourse-resources` skill for full `resource_types` schema.

### `jobs`

The work. Each job has a `name` and a `plan` (ordered list of steps). See `references/jobs.md` for full job schema.

### `var_sources`

Pluggable credential managers evaluated at build time. Each entry has `name`, `type`, and `config`. Example types: `vault`, `credhub`, `dummy`, `ssm`.

```yaml
var_sources:
  - name: prod-vault
    type: vault
    config:
      url: https://vault.internal
      role_id: ((vault_role_id))
      secret_id: ((vault_secret_id))
```

### `groups`

Groups jobs into named tabs in the Concourse UI. Supports glob patterns. Once any group is present, all jobs must appear in at least one group.

```yaml
groups:
  - name: build
    jobs: [unit, integration]
  - name: deploy
    jobs: [deploy-staging, deploy-prod]
  - name: all
    jobs: ["*"]
```

### `display`

Pipeline-level UI customization. Currently supports `background_image`.

```yaml
display:
  background_image: https://example.com/bg.png
```

## Minimal valid pipeline

The smallest pipeline that does real work: one resource, one job, one get-triggered task.

```yaml
resources:
  - name: source
    type: git
    source:
      uri: https://github.com/myorg/myrepo
      branch: main

jobs:
  - name: unit
    plan:
      - get: source
        trigger: true
      - task: test
        config:
          platform: linux
          image_resource:
            type: registry-image
            source: { repository: golang, tag: "1.23" }
          inputs:
            - name: source
          run:
            path: source/ci/test.sh
```

## Gotchas

- `resources:` items with no referencing `get`/`put` are valid but Concourse will still check them on the check interval — wasteful. Remove unused resources.
- `groups:` is all-or-nothing: add one group and every job that isn't in a group disappears from the UI.
- `var_sources:` config values are themselves interpolated from other credential sources, so order matters if you have chained lookups.
- `display.background_image` must be a publicly reachable URL (Concourse fetches it in the browser, not on the server).

## See also

- `references/jobs.md` — job-level schema
- `concourse-resources` skill — resource and resource_type configuration
- `concourse-ops` skill — var_sources, credential managers, fly set-pipeline
