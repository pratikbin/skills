# semver-resource.md — `semver` resource type schema and patterns

Stores and bumps a single monotonically-increasing semantic version number in a persistent backend.

---

## Schema

Declare the resource type first (not built-in):

```yaml
resource_types:
  - name: semver
    type: registry-image
    source:
      repository: concourse/semver-resource
      tag: "1.6.0"
```

### git driver (recommended — atomic, no extra infra)

```yaml
resources:
  - name: app-version
    type: semver
    source:
      driver: git                              # required; git | s3 | gcs | swift
      uri: git@github.com:example/version.git # required; repo that holds the version file
      branch: version                          # required; dedicated branch, NOT your main branch
      file: version                            # required; filename in the repo
      private_key: ((git.private-key))         # required for SSH URI
      initial_version: "0.0.1"                # optional; created if file doesn't exist
      git_user: "CI Bot <ci@example.com>"      # optional; author for bump commits
      git_config:                              # optional
        - name: user.email
          value: ci@example.com
        - name: user.name
          value: CI Bot
      commit_message: "bump version to %version%" # optional; %version% is substituted
```

### s3 driver (no git infra needed; eventual consistency)

```yaml
resources:
  - name: app-version
    type: semver
    source:
      driver: s3
      bucket: my-version-bucket
      key: version/app
      access_key_id: ((aws.key-id))
      secret_access_key: ((aws.secret))
      region_name: us-east-1
      initial_version: "0.1.0"
```

### gcs driver

```yaml
resources:
  - name: app-version
    type: semver
    source:
      driver: gcs
      bucket: my-version-bucket
      key: version/app
      json_key: ((gcs.json-key))
      initial_version: "0.1.0"
```

---

## `get` params

```yaml
- get: app-version
  params:
    bump: patch          # optional; major | minor | patch | final; bump before get
    pre: rc              # optional; append pre-release label (e.g. "rc"); implies pre_without_version if version is already pre
    pre_without_version: false # optional; rc.1 → rc (no numeric suffix)
```

The version is written to a file `number` in the fetched directory (`app-version/number`).

---

## `put` params

```yaml
- put: app-version
  params:
    file: app-version/number    # required (or bump); read version from this file
    bump: minor                 # optional; major | minor | patch | final | pre
    pre: alpha                  # optional; set pre-release label
    pre_without_version: false  # optional; suppress numeric suffix on pre label
```

`file` and `bump` are mutually exclusive in practice: use `file` to set an explicit version, `bump` to increment.

---

## Bump policy

| value | effect |
|---|---|
| `major` | 1.2.3 → 2.0.0 |
| `minor` | 1.2.3 → 1.3.0 |
| `patch` | 1.2.3 → 1.2.4 |
| `final` | 1.2.3-rc.1 → 1.2.3 |
| `pre` | 1.2.3 → 1.2.4-rc.1 (with `pre: rc`) |

Bumps are atomic for drivers that support compare-and-swap (git, gcs). If another job bumped the version since you read it, the driver retries the bump.

---

## Examples

### git-driver release pipeline — bump patch on every merge

```yaml
resources:
  - name: app-version
    type: semver
    source:
      driver: git
      uri: git@github.com:example/app-version.git
      branch: version
      file: version
      private_key: ((git.deploy-key))
      initial_version: "0.1.0"

jobs:
  - name: release
    plan:
      - get: source
        passed: [test]
      - get: app-version
        params:
          bump: patch          # bump before reading the version
      - task: build-release
        # produces release artifacts tagged with app-version/number
      - put: release-bucket
        params:
          file: release/myapp-*.tar.gz
      - put: app-version
        params:
          file: app-version/number  # persist the bumped version
```

---

### s3-driver for fast iteration — bump minor on feature branch

```yaml
resources:
  - name: feature-version
    type: semver
    source:
      driver: s3
      bucket: ci-versions
      key: feature/my-feature
      access_key_id: ((aws.key-id))
      secret_access_key: ((aws.secret))
      initial_version: "1.0.0-dev.1"

jobs:
  - name: bump-feature-version
    plan:
      - put: feature-version
        params:
          bump: minor
          pre: dev
```

---

## Gotchas

- `put` step **cannot** be used as a job trigger. You cannot set `trigger: true` on a put step.
- `passed:` is **not** allowed on a `put` step — only on `get`.
- The git driver commits to the version branch on every bump. Use a dedicated branch (e.g. `version`), never your main source branch.
- `get_latest: true` (s3 driver) always fetches the latest version; you cannot pin an old version when this is set.
- `initial_version` is only used when the version file/object does not exist yet. It won't reset a version that already exists.
- pre-release bumps: `pre: rc` on `1.2.3` produces `1.2.4-rc.1` (bumps patch + adds pre). To go from `1.2.3-rc.1` to `1.2.3-rc.2`, use `bump: pre` with `pre: rc` again.
- `final` removes the pre-release suffix: `1.2.3-rc.2 → 1.2.3`.

---

## See also

- [versioning.md](versioning.md) — `version:` pinning, `passed:` semantics
- [s3-resource.md](s3-resource.md) — storing release artifacts alongside version files
- [anti-patterns.md](anti-patterns.md) — `put` as trigger (not allowed)
- [core-types.md](core-types.md) — when semver vs other approaches
