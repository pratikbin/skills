# yaml-anchors.md — YAML anchors, aliases, and merge keys in pipelines

YAML anchors let you define a block once and reuse it. Concourse does not process them — they are expanded by the YAML parser before the pipeline config reaches Concourse. They work in any pipeline YAML file consumed by `fly set-pipeline`.

## Syntax

```yaml
# Define an anchor: &anchor-name on the value
- name: my-resource
  type: registry-image
  icon: &release-icon package-variant-closed   # anchor on a scalar

# Reference an anchor: *anchor-name
- name: other-resource
  type: registry-image
  icon: *release-icon                          # expands to: package-variant-closed

# Merge keys: <<: *anchor-name merges a map into the current map
.common-task-config: &common-task            # convention: dot-prefixed key ignored by Concourse
  timeout: 10m
  attempts: 2
  tags: [linux]

- task: build
  file: ci/tasks/build.yml
  <<: *common-task                           # merges timeout, attempts, tags into this task step

- task: test
  file: ci/tasks/test.yml
  <<: *common-task                           # same modifiers applied
  timeout: 20m                               # override: local key wins over merged key
```

Merge key `<<:` only works with maps. When the same key appears in both the local map and the merged map, the **local key wins**.

## Real-world examples from concourse/ci

### Scalar anchor for icon reuse (`concourse.yml`)

From `concourse/ci` pipelines, a single icon string reused across many resource declarations:

```yaml
resource_types:
  - name: bosh-io-release
    type: registry-image
    source:
      repository: concourse/bosh-io-release-resource

resources:
  - name: concourse-release
    type: bosh-io-release
    icon: &release-icon package-variant-closed    # define here
    source:
      repository: concourse/concourse

  - name: bpm-release
    type: bosh-io-release
    icon: *release-icon                           # reuse — same icon, no duplication
    source:
      repository: cloudfoundry/bpm-release

  - name: postgres-release
    type: bosh-io-release
    icon: *release-icon
    source:
      repository: cloudfoundry/postgres-release
```

Without the anchor, updating the icon across 10+ resources requires 10 edits.

### Map anchor for repeated notification block

A Slack notification step repeated across multiple jobs:

```yaml
.slack-failure-notify: &slack-failure-notify
  task: notify-slack
  file: ci/tasks/slack-notify.yml
  params:
    WEBHOOK: ((slack_webhook))
    COLOR: danger

jobs:
  - name: build
    plan:
      - get: source
        trigger: true
      - task: compile
        file: ci/tasks/compile.yml
    on_failure:
      <<: *slack-failure-notify

  - name: test
    plan:
      - get: source
        trigger: true
        passed: [build]
      - task: run-tests
        file: ci/tasks/test.yml
    on_failure:
      <<: *slack-failure-notify
    on_error:
      <<: *slack-failure-notify
```

### Anchor for a full resource block

```yaml
.git-resource-defaults: &git-defaults
  type: git
  check_every: never       # checked only when manually triggered
  icon: git

resources:
  - name: app-source
    <<: *git-defaults
    source:
      uri: https://github.com/myorg/app
      branch: main

  - name: infra-source
    <<: *git-defaults
    source:
      uri: https://github.com/myorg/infra
      branch: main
```

Both resources share type, check_every, and icon. Only `source` differs.

### Anchor for a get step with common modifiers

```yaml
.get-with-trigger: &get-with-trigger
  trigger: true

jobs:
  - name: deploy
    plan:
      - in_parallel:
          - get: artifact
            <<: *get-with-trigger
            passed: [build]
          - get: config
            <<: *get-with-trigger
            passed: [validate]
```

## Conventions

- Prefix anchor-holding keys with `.` (dot) to signal they are "virtual" — Concourse ignores unrecognized top-level keys in some versions, but the convention is cleaner.
- Name anchors after the semantic concept, not the location (`&release-icon` not `&resource-2-icon`).
- Keep anchors near their first use, not at the top of the file, unless they are truly global.

## When to use anchors

Use when:
- The same block repeats **3 or more times**.
- The block has a meaningful name (notification config, common resource defaults).
- The file is consumed directly by `fly set-pipeline` (anchors only work in the file they're defined in — they don't cross file boundaries).

## When to switch to ytt

YAML anchors are processed once at parse time. They cannot:
- Loop over a list to generate repeated blocks.
- Apply conditionals (if/else).
- Cross file boundaries.
- Be parameterized (you can't call an anchor with different arguments).

Switch to [ytt](https://carvel.dev/ytt/) or another templating tool when you need:
- Loops: generate 10 resources from a list.
- Conditionals: include a job only for prod env.
- Functions: generate a job config from parameters.
- Multi-file includes: share blocks across pipeline files.

Concourse docs explicitly recommend reaching for a templating tool rather than extending YAML's limited substitution model.

## Gotchas

- Anchors are file-scoped. An anchor in `pipeline.yml` is not visible in `vars.yml` or `task.yml`.
- The merge key `<<:` only merges maps, not sequences. Merging a list into a list is not supported.
- When the same key appears in both the anchor and the local map, the **local key wins** silently. This can mask mistakes — double-check that overrides are intentional.
- `fly validate-pipeline` processes the expanded YAML (post-anchor resolution). Anchor errors show up as YAML parse errors before Concourse sees anything.
- Some YAML parsers silently drop anchor definitions when they appear inside a non-standard top-level key (like `.config:`). Test with `fly validate-pipeline -c pipeline.yml --output` to see the expanded form.

## See also

- `references/schema.md` — top-level pipeline structure
- `concourse-ops` skill — ytt, spruce, other templating tools used with fly set-pipeline
