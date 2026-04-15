# Uncloud compose support matrix

Selective reference. If the user asks "does Uncloud support X?" check here first.

Legend: ✅ supported, ⚠️ limited, ❌ not supported.

## Service-level keys

| Key | Status | Notes |
|-----|--------|-------|
| `build` | ✅ | Build context and Dockerfile |
| `cap_add` | ✅ | Kernel capabilities |
| `cap_drop` | ✅ | Kernel capabilities |
| `command` | ✅ | Override container command |
| `configs` | ✅ | File and inline configs |
| `cpus` | ✅ | CPU limit |
| `depends_on` | ⚠️ | Deployment order only. Use `x-pre_deploy` for "wait for healthy" |
| `devices` | ✅ | Device mappings |
| `dns` | ❌ | Built-in service discovery supersedes it |
| `dns_search` | ❌ | Built-in service discovery supersedes it |
| `entrypoint` | ✅ | Override ENTRYPOINT |
| `env_file` | ✅ | External env file |
| `environment` | ✅ | Env vars |
| `healthcheck` | ✅ | Used by rolling deploy to gate updates |
| `image` | ✅ | Supports image tag templates (see extensions) |
| `labels` | ✅ | Arbitrary Docker labels |
| `networks` | ❌ | One flat overlay per cluster; field is ignored/rejected |
| `pid` | ⚠️ | `pid: host` only |
| `ports` | ⚠️ | Host mode only; use `x-ports` for HTTP/HTTPS via Caddy |
| `privileged` | ✅ | Run privileged |
| `pull_policy` | ✅ | `always`, `missing`, `never` |
| `read_only` | ✅ | Read-only root fs |
| `restart` | ✅ | Docker-level restart policy |
| `secrets` | ❌ | Use `env_file` or `configs` |
| `security_opt` | ✅ | Like seccomp profiles |
| `shm_size` | ✅ | `/dev/shm` size |
| `stop_grace_period` | ✅ | Time before SIGKILL |
| `sysctls` | ✅ | Kernel params |
| `tmpfs` | ✅ | In-memory mounts |
| `tty` | ✅ | Allocate TTY |
| `ulimits` | ✅ | nofile, nproc, etc. |
| `user` | ✅ | Container user |
| `volumes` | ✅ | Named, bind, tmpfs |

## `deploy.*`

| Key | Status | Notes |
|-----|--------|-------|
| `mode` | ✅ | `global` or `replicated` |
| `replicas` | ✅ | Number of containers |
| `resources` | ✅ | CPU/memory limits/reservations |
| `placement` | ❌ | Use `x-machines` extension |
| `restart_policy` | ❌ | Use service-level `restart` instead |
| `rollback_config` | ❌ | Uncloud has its own rollback logic |
| `update_config.order` | ⚠️ | `start-first` / `stop-first` |
| `update_config.monitor` | ⚠️ | Duration for monitoring new containers |
| `update_config.*` (other) | ❌ | parallelism, delay, failure_action, max_failure_ratio — not honored |

## Top-level

| Key | Status | Notes |
|-----|--------|-------|
| `services` | ✅ | Required |
| `volumes` | ✅ | Named volumes |
| `configs` | ✅ | File and inline |
| `secrets` | ❌ | Use `env_file` or `configs` |
| `networks` | ❌ | Single flat cluster network; remove them |
| `x-context` | ✅ (Uncloud) | Locks file to a cluster context |

## Uncloud `x-*` extensions

| Key | Level | Purpose |
|-----|-------|---------|
| `x-context` | top-level | Lock file to a cluster context |
| `x-ports` | service | Publish HTTP/HTTPS via Caddy or TCP/UDP via host mode |
| `x-caddy` | service | Inline Caddyfile snippet (Go-templated) |
| `x-machines` | service | Restrict to a subset of machines |
| `x-pre_deploy` | service | Run a one-off command before rolling deploy |

## Escape hatch

If a feature is listed as ❌ but the user really needs it, file a feature request:

- GitHub: `https://github.com/psviderski/uncloud/discussions`
- Discord: `https://uncloud.run/discord`

Do not silently ignore their requirement. Explain the limitation and a workaround if one exists.
