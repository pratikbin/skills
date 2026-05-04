# schema.md — top-level schema for `resource{}` and `resource_type{}`

Every pipeline config declares resources in a top-level `resources:` list. Custom types go in `resource_types:`.

---

## resource{} schema

```yaml
resources:
  - name: my-repo                 # required; identifier, unique within the pipeline
    type: git                     # required; built-in type or a name from resource_types
    icon: github                  # optional; mdi icon name, shown in UI
    public: false                 # optional; expose version metadata to unauthenticated callers
    check_every: 1m               # optional; polling interval; "never" to disable polling
    webhook_token: ((wh-token))   # optional; enables push-based check via webhook URL
    tags: []                      # optional; route check containers to tagged workers
    expose: false                 # optional; deprecated alias for public
    source:                       # optional; arbitrary map, passed to check/in/out as-is
      uri: https://github.com/example/repo.git
      branch: main
    version:                      # optional; pin to a specific version at pipeline level
      ref: abc123def456
```

Fields:

| field | type | required | notes |
|---|---|---|---|
| `name` | identifier | yes | unique within pipeline |
| `type` | string | yes | built-in or resource_type.name |
| `source` | map | no | passed to check/in/out; interpolated via `((...))` |
| `version` | map | no | pipeline-level version pin; overridden by get step `version:` |
| `check_every` | duration | no | `"1m"`, `"4h"`, `"24h"`, `"never"` |
| `public` | bool | no | version history visible without auth |
| `expose` | bool | no | deprecated alias for `public` |
| `icon` | string | no | [mdi icon](https://pictogrammers.com/library/mdi/) slug |
| `webhook_token` | string | no | enables `/check/webhook?webhook_token=...` endpoint |
| `tags` | list of string | no | worker tag selector for check containers |

---

## resource_type{} schema

```yaml
resource_types:
  - name: slack-notification       # required; identifier used in resource.type
    type: registry-image           # required; type of container image to use
    source:                        # optional; source config for the image fetch
      repository: cfcommunity/slack-notification-resource
      tag: latest
    defaults:                      # optional; merged into every resource.source using this type
      url: ((slack.webhook-url))
    params: {}                     # optional; passed to every get of the type image
    check_every: 24h               # optional; how often to check for new versions of the type image
    privileged: false              # optional; run check/in/out containers as root
    unique_version_history: false  # optional; isolate version history per resource instead of sharing
```

Fields:

| field | type | required | notes |
|---|---|---|---|
| `name` | identifier | yes | used as `type:` in resource declarations |
| `type` | string | yes | almost always `registry-image` |
| `source` | map | no | locates the container image |
| `defaults` | map | no | merged (low priority) into every resource.source |
| `params` | map | no | passed to every `get` that fetches the type image |
| `check_every` | duration | no | how often to re-check for new type image versions |
| `privileged` | bool | no | grants root to check/in/out; requires operator allowlist |
| `unique_version_history` | bool | no | see [global-resources.md](global-resources.md) |

---

## Minimal examples

### Declare a pinned registry-image resource with a webhook

```yaml
resources:
  - name: app-image
    type: registry-image
    check_every: never           # only update when webhook fires
    webhook_token: ((img-webhook-token))
    source:
      repository: ghcr.io/example/app
      tag: "2.1.0"
      username: ((ghcr.username))
      password: ((ghcr.token))
```

### Declare a custom resource type from a private registry

```yaml
resource_types:
  - name: sentry-release
    type: registry-image
    source:
      repository: registry.internal/ci/sentry-release-resource
      tag: "0.3.1"
      username: ((registry.user))
      password: ((registry.pass))
    check_every: 12h
    defaults:
      org: my-org
      auth_token: ((sentry.token))
```

---

## Gotchas

- `version:` at resource level sets a pipeline-wide pin. A `get` step with its own `version:` wins.
- `check_every: never` stops automated polling entirely; you still get manual check and webhook check.
- `public: true` exposes version history (refs, digest, timestamps) to anyone who can reach the ATC. Do not use on private repos unless that is intentional.
- `privileged: true` on a resource_type requires the operator to have whitelisted privileged resource types; it will fail silently otherwise.
- `defaults` are merged before `source`, so a resource can override any default by specifying the same key in `source`.

---

## See also

- [core-types.md](core-types.md) — which type to pick
- [trigger-tuning.md](trigger-tuning.md) — `check_every`, `webhook_token`, `tags`
- [custom-types.md](custom-types.md) — writing your own resource type
- [global-resources.md](global-resources.md) — dedup checks across pipelines
