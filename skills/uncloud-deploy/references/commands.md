# Deployment command reference

## `uc deploy`

```
uc deploy [FLAGS] [SERVICE...]
```

Deploy services from a Compose file. All services by default; pass names to target a subset.

| Flag | Default | Description |
|------|---------|-------------|
| `-f, --file` | `compose.yaml` | Compose files (repeatable, merged) |
| `-p, --profile` | — | Compose profiles to enable (repeatable) |
| `--no-build` | false | Skip building images even if `build:` is set |
| `--build-pull` | false | Always pull newer base images before building |
| `--no-cache` | false | Do not use Docker build cache |
| `--build-arg KEY=VAL` | — | Build-time variable (repeatable) |
| `--recreate` | false | Recreate containers even if config + image unchanged |
| `--skip-health` | false | Skip monitor period + healthcheck (emergency only) |
| `-y, --yes` | false | Auto-confirm plan. `UNCLOUD_AUTO_CONFIRM=1` also works |

## `uc build`

```
uc build [FLAGS] [SERVICE...]
```

Build images from compose `build:` sections using local Docker.

| Flag | Default | Description |
|------|---------|-------------|
| `-f, --file` | `compose.yaml` | Compose files |
| `-p, --profile` | — | Compose profiles |
| `--check` | false | Validate build config, do not build |
| `--deps` | false | Build declared dependencies too |
| `--no-cache` | false | Skip cache |
| `--pull` | false | Pull newer base images |
| `--build-arg KEY=VAL` | — | Build-time var |
| `--push` | false | Push built images to cluster machines (via Unregistry) |
| `--push-registry` | false | Push to external registries (Docker Hub etc.) |
| `-m, --machine` | all | Restrict `--push` to specific machines |

`--push` requires no registry — it uses Unregistry inside Uncloud daemons on each machine.

## `uc run`

```
uc run [FLAGS] IMAGE [COMMAND...]
```

One-off imperative run. Creates a service. Most important flags:

| Flag | Purpose |
|------|---------|
| `-n, --name` | Service name |
| `-p, --publish` | Port (same syntax as `x-ports`: HTTP via Caddy or `@host` for TCP/UDP) |
| `-e, --env` | `VAR=value` or just `VAR` to pass through |
| `--env-file` | env file path |
| `-m, --machine` | Placement constraint (repeatable / comma-sep) |
| `--mode` | `replicated` (default) or `global` |
| `--replicas` | Number of replicas for replicated mode |
| `--pull` | `always`, `missing` (default), `never` |
| `--entrypoint` | Override ENTRYPOINT (empty string resets) |
| `-u, --user` | User |
| `--cpu` | Max CPU (decimal, e.g. `0.5`, `2.25`) |
| `--memory` | Max memory (bytes, `512m`, `1g`) |
| `--shm-size` | `/dev/shm` size |
| `--privileged` | Privileged mode |
| `--caddyfile` | Custom Caddyfile (incompatible with non-`@host` ports) |

## `uc image push`

```
uc image push IMAGE [FLAGS]
```

Upload a local Docker image to cluster machines via Unregistry. Only transfers missing layers.

| Flag | Default | Description |
|------|---------|-------------|
| `-m, --machine` | all | Machines to push to |
| `--platform` | local default | Specific platform (e.g. `linux/amd64`) — requires local containerd image store for multi-platform |

## `uc images`

```
uc images [IMAGE] [FLAGS]
```

List images on cluster machines. Optional filter by image name or pattern.

| Flag | Default | Description |
|------|---------|-------------|
| `-m, --machine` | all | List from specific machines |

Examples:

```bash
uc images
uc images myapp
uc images "myapp:1.*"
uc images myapp -m vps1
```

## Global flags (inherited)

| Flag | Env | Description |
|------|-----|-------------|
| `--connect` | `UNCLOUD_CONNECT` | Skip config, connect directly |
| `-c, --context` | `UNCLOUD_CONTEXT` | Pick a context from the config |
| `--uncloud-config` | `UNCLOUD_CONFIG` | Path to config file |
| `-y, --yes` (deploy/machine) | `UNCLOUD_AUTO_CONFIRM` | Auto-confirm plans |
