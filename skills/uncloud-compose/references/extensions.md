# Uncloud Compose extensions — full reference

## `x-context` (top-level)

```yaml
x-context: prod

services:
  web:
    image: nginx
```

- Top-level key, **not** a service-level one.
- `uc deploy`, `uc build`, `uc logs` and anything else that loads this file will use the named context.
- `--context` / `--connect` CLI flags override it. If neither is set and `x-context` is absent, `current_context` from the Uncloud config is used.
- Share safely: every teammate needs the same context name locally.

## `x-ports` (service-level)

Publish a service port. Repeatable list.

### HTTP/HTTPS via Caddy

```
[hostname:]container_port[/protocol]
```

- `hostname` — omit to use `<service>.<cluster-domain>` (only if a managed domain is reserved).
- `container_port` — port the container listens on.
- `protocol` — `http` or `https`. Default `https`.

Examples:

| Value | Result |
|-------|--------|
| `8000/https` | `https://<service>.<cluster-domain>` → container:8000 |
| `app.example.com:8080/https` | `https://app.example.com` → container:8080 |
| `internal.example.com:8080/http` | plain HTTP (no Let's Encrypt) |

### TCP/UDP via host mode

```
[host_ip:]host_port:container_port[/protocol]@host
```

- `host_ip` — bind to specific interface. Omit to bind all.
- `host_port` — port on the host machine.
- `container_port` — port inside the container.
- `protocol` — `tcp` or `udp`. Default `tcp`.

Examples:

| Value | Result |
|-------|--------|
| `127.0.0.1:5432:5432@host` | Postgres on loopback only |
| `53:5353/udp@host` | UDP 53 on all interfaces → container 5353 |
| `0.0.0.0:1883:1883@host` | MQTT on all interfaces |

### Notes

- HTTP ports bypass Caddy if and only if you use `@host`.
- HTTPS on `@host` gives you no Let's Encrypt. Use Caddy (plain `x-ports` form) instead.
- Multiple hostnames for the same container port: list them as separate `x-ports` entries.

## `x-caddy` (service-level)

Inline Caddyfile snippet templated with Go's `text/template`.

```yaml
services:
  web:
    image: nginx
    x-caddy: |
      example.com {
        reverse_proxy {{upstreams 80}}
      }
```

### Template helpers

| Call | Returns |
|------|---------|
| `{{upstreams}}` | Healthy IPs of the current service, default port |
| `{{upstreams 8000}}` | Current service, port 8000 |
| `{{upstreams "api" 9000}}` | `api` service, port 9000 |
| `{{.Name}}` | Current service name |
| `{{.Upstreams}}` | `map[string][]string` of service name → container IPs |

### Semantics

- The snippet is re-rendered and Caddy reloads automatically on health/status changes.
- Invalid snippets are dropped with an error comment in `uc caddy config` output. They do **not** break other services.
- `x-caddy` is per-service. Multiple services can publish config; Caddy merges them.
- For **global** Caddy config (snippets, global options, wildcard certs via DNS challenge), customize the `caddy` service itself.

## `x-machines` (service-level)

Restrict a service to a set of machines.

```yaml
services:
  db:
    image: postgres:16
    x-machines:
      - db-1

  web:
    image: nginx
    x-machines:
      - edge-1
      - edge-2
      - edge-3
```

Short form for a single machine:

```yaml
x-machines: db-1
```

Combines with `deploy.mode: global` to run one replica per machine from the subset.

## `x-pre_deploy` (service-level)

Run a one-off command in a throwaway container **before** the rolling deploy starts. Uses the service's image and inherits its volumes, environment, placement, and compute limits.

```yaml
services:
  web:
    build: .
    x-pre_deploy:
      command: python manage.py migrate
      environment:
        LOG_LEVEL: DEBUG
      timeout: 10m
      user: app
      privileged: false
```

### Attributes

| Attribute | Type | Default | Notes |
|-----------|------|---------|-------|
| `command` | string or list | **required** | Same format as Compose `command:` |
| `environment` | map or list of `KEY=VALUE` | — | Extends/overrides service env |
| `timeout` | duration (`30s`, `10m`, `1h30m`) | `5m` | Kill + fail the deploy if exceeded |
| `user` | string | service's value | `user`, `UID`, `user:group`, `UID:GID` |
| `privileged` | bool | service's value | Override privileged mode |

### Environment variable

- `UNCLOUD_HOOK_PRE_DEPLOY=true` is injected automatically so your app can detect it's running as a hook.

### Failure handling

- **Non-zero exit code** → deploy fails immediately, no containers roll over, the hook container is kept for `uc logs`.
- **Timeout** → container is killed, deploy fails, container kept for inspection.
- **Retry** → `uc deploy` re-runs the hook. Make commands idempotent. Migration tools usually are.

### Multi-command pattern

```yaml
x-pre_deploy:
  command: sh -c "python manage.py migrate && python manage.py collectstatic --no-input"
```

### Script-in-image pattern

```yaml
x-pre_deploy:
  command: ./scripts/pre_deploy.sh
```

```bash
#!/bin/bash
set -e
python manage.py migrate
python manage.py collectstatic --no-input
```

## Image tag template

Go `text/template` inside the `image:` field of a service with `build:`. Rendered before the image is built.

### Default

If `image:` is omitted for a service with `build:`, Uncloud uses:

```
uncloud-{project-name}-{service-name}:{{.GitSHA}}
```

### Functions

| Function | Example |
|----------|---------|
| `gitsha [length]` | `{{gitsha 7}}` → `84d33bb` |
| `gitdate "layout" ["tz"]` | `{{gitdate "2006-01-02"}}` → `2025-10-30` |
| `date "layout" ["tz"]` | `{{date "2006-01-02"}}` → `2025-10-31` (no git required) |

`layout` follows Go's time package. Reference layout is `2006-01-02 15:04:05` (month-day-year-hour-minute-second = 01-02-2006 03:04:05 PM).

### Common layouts

| Layout | Example |
|--------|---------|
| `2006-01-02` | `2025-10-30` |
| `20060102` | `20251030` |
| `20060102-150405` | `20251030-223604` |
| `2006-01-02T15:04:05Z07:00` | RFC 3339 |

### Timezone

IANA timezone names: `UTC` (default), `America/New_York`, `Europe/London`, `Australia/Brisbane`, etc.

### Fields (less common)

| Field | Meaning |
|-------|---------|
| `{{.Project}}` | Compose project name |
| `{{.Service}}` | Service name |
| `{{.GitSHA}}` | Current git commit SHA |
| `{{.GitDate}}` | Current git commit time |
| `{{.Date}}` | Current date/time |

### Env var interpolation

Standard Compose `${VAR}` and `${VAR:-default}` interpolation happens **before** template rendering:

```yaml
image: myapp:{{gitsha 7}}.${GITHUB_RUN_ID:-local}
```

### Notes

- If the working directory is not a git repo, `gitsha` and `gitdate` return empty strings. Add a fallback.
- Rendering happens once per `uc build` / `uc deploy`, so the same tag is used across all services in the project for that run.
