# custom-types.md — when to write a custom resource type vs a scripted task

A custom resource type is a container image that implements three scripts. Worth the investment for reusable, well-encapsulated integrations; often overkill for one-off automation.

---

## When to write a custom resource type

Write one when:
- The integration is used across 3+ pipelines, and copy-pasting a task is painful.
- The integration has meaningful version semantics (check emits ordered versions that Concourse can track).
- The integration needs to be a trigger (a task cannot trigger a job; a resource can).
- The integration wraps an external system that emits new versions over time (issue tracker, artifact store, message queue).

Use a scripted task instead when:
- The operation is one-off or pipeline-specific.
- There's no version concept (just run a script).
- You need rapid iteration or heavy debugging — tasks are easier to iterate on than container images.
- The operation is a simple HTTP call or shell script.

---

## The three scripts

Every custom resource type is a container image with three executable scripts at `/opt/resource/`:

### `/opt/resource/check` — detect new versions

- Reads JSON from stdin: `{"source": {...}, "version": {...}}`
- `source` is the resource's `source:` config map.
- `version` is the last known version (omit on first check).
- Must print a JSON array of versions to stdout, in chronological order (oldest first), including the current version if still valid.

```bash
#!/bin/bash
set -eu
payload=$(cat)
# ... detect new versions ...
echo '[{"id": "v1"}, {"id": "v2"}]'
```

### `/opt/resource/in` — fetch a version

- Called with the destination directory as `$1`.
- Reads JSON from stdin: `{"source": {...}, "version": {...}, "params": {...}}`
- Must fetch the resource into `$1`.
- Must print JSON to stdout: `{"version": {...}, "metadata": [{"name": "key", "value": "val"}]}`

```bash
#!/bin/bash
set -eu
destination=$1
payload=$(cat)
# ... fetch version into $destination ...
echo '{"version": {"id": "v1"}, "metadata": [{"name": "url", "value": "https://..."}]}'
```

### `/opt/resource/out` — create a new version

- Called with the sources directory as `$1` (the build's artifact root).
- Reads JSON from stdin: `{"source": {...}, "params": {...}}`
- Must create or update the resource.
- Must print JSON to stdout: `{"version": {...}, "metadata": [...]}`

```bash
#!/bin/bash
set -eu
sources=$1
payload=$(cat)
# ... create the resource version ...
echo '{"version": {"id": "new-v"}, "metadata": []}'
```

---

## resource_type{} schema for distributing a custom type

```yaml
resource_types:
  - name: my-custom-type
    type: registry-image
    source:
      repository: registry.internal/ci/my-custom-type
      tag: "1.2.0"
      username: ((registry.user))
      password: ((registry.pass))
    defaults:                      # optional; merged into every resource.source using this type
      api_url: https://api.internal
    params: {}                     # optional; passed to every get of the type image
    check_every: 12h               # optional; how often to check for new versions of the type itself
    privileged: false              # optional; run check/in/out as root (operator must allow)
    unique_version_history: false  # optional; isolate version history per pipeline resource
```

The container image IS the resource type. Distribute it via a registry. Pin the tag in `resource_types` — never use `latest`.

---

## `defaults` — shared source config

```yaml
resource_types:
  - name: slack-notification
    type: registry-image
    source:
      repository: cfcommunity/slack-notification-resource
    defaults:
      url: ((slack.webhook-url))    # every resource using this type inherits this
```

```yaml
resources:
  - name: deploy-slack
    type: slack-notification
    source:
      channel: "#deploys"           # source.url comes from defaults; channel is added here
```

`defaults` are merged at lower priority than `source`. A resource can override any default by specifying the same key in its `source`.

---

## `privileged` — root access

```yaml
resource_types:
  - name: docker-build-type
    type: registry-image
    source:
      repository: concourse/oci-build-task
    privileged: true               # needs root to run the container build daemon
```

`privileged: true` grants root to all containers spawned by this type (check, in, out). Requires the Concourse operator to have whitelisted privileged resource types (`--allow-privileged-resource-types`). Fails silently (or with a cryptic error) if not whitelisted.

---

## `unique_version_history`

```yaml
resource_types:
  - name: my-type
    type: registry-image
    source:
      repository: registry.internal/my-type
    unique_version_history: true   # version history is not shared across pipelines
```

By default, when global resources is enabled, resources with identical `type` + `source` share version history. `unique_version_history: true` opts out — each resource tracks its own version history independently. Required for types that embed auth credentials in version data, or for types where version identity is inherently per-pipeline.

See [global-resources.md](global-resources.md).

---

## Container-as-distribution pattern

Build and push the resource type image in a separate pipeline, then reference it from consumer pipelines:

```yaml
# In the resource-type build pipeline:
jobs:
  - name: build-and-push-resource-type
    plan:
      - get: source
        trigger: true
      - task: build
        # produces image/image.tar
      - put: type-image
        params:
          image: image/image.tar
          version: "1.2.0"

# In consumer pipelines:
resource_types:
  - name: my-type
    type: registry-image
    source:
      repository: registry.internal/ci/my-type
      tag: "1.2.0"          # pin to a specific version; never float on latest
```

---

## Gotchas

- Scripts must be executable (`chmod +x`). A non-executable script causes a cryptic "exec format error".
- All three scripts must exist even if `in` or `out` are no-ops. Return `{"version": {}, "metadata": []}` from a no-op.
- stdin is your only input channel. Do not rely on environment variables for source config — read from the JSON on stdin.
- stdout is the output channel for version/metadata JSON. All logs must go to stderr.
- `defaults` are merged at pipeline apply time — they don't update existing resources until you re-fly.
- `unique_version_history` has no effect unless the operator has enabled global resources (`CONCOURSE_ENABLE_GLOBAL_RESOURCES`).

---

## See also

- [schema.md](schema.md) — `resource_type{}` full field reference
- [global-resources.md](global-resources.md) — version sharing and `unique_version_history`
- [core-types.md](core-types.md) — built-in types that cover most cases
- `concourse-tasks` skill — `image_resource` patterns for task containers
