---
name: uncloud-deploy
description: Build, push, and roll out services on an Uncloud cluster. Use this whenever the user wants to run `uc deploy`, `uc run`, `uc build`, or `uc image push`, ship code from a compose file, do a zero-downtime rolling update, push locally built images to cluster machines, wire up CI/CD for Uncloud, configure rollbacks and health-check gating, or target a specific context/machine for a deployment. Trigger on phrases like "deploy to uncloud", "uc deploy", "uc run", "uc build", "ship this app", "rolling update", "push my image to the cluster", "uncloud ci pipeline", "skip health checks emergency deploy", "private registry with uncloud", or any request to get code running on an Uncloud cluster.
---

# Uncloud deployment workflows

This skill is the go-to for **shipping code** onto an already-set-up Uncloud cluster. If the cluster does not exist yet, use `uncloud-cluster` first. If the user is authoring or debugging a compose file, use `uncloud-compose`. If they're checking logs or troubleshooting a running service, use `uncloud-ops`.

Core commands in scope:

| Command | Purpose |
|---------|---------|
| `uc run` | One-off imperative deployment (no compose file) |
| `uc deploy` | Declarative deployment from `compose.yaml` |
| `uc build` | Build images from compose `build:` sections |
| `uc image push` | Push local Docker images straight to cluster machines |
| `uc images` | List images currently on cluster machines |

## Golden workflows

### 1. Hobbyist: publish an existing image in 30 seconds

```bash
uc run --publish 80/https docker.io/excalidraw/excalidraw
```

`uc run` is the Docker-style equivalent of `docker run`. It creates a service (auto-named or `-n excalidraw`), pulls the image, publishes port 80 through Caddy as HTTPS, and serves it at `https://excalidraw.<cluster-domain>.uncld.dev` if a managed cluster domain is reserved.

Once they like the result, convert to a compose file (see `uncloud-compose`) and from then on use `uc deploy` so the state is in Git.

### 2. Deploy from compose.yaml (the main workflow)

```bash
uc deploy
```

Looks for `compose.yaml` in the current directory. Uncloud:

1. Validates the compose file
2. If any service has `build:`, builds the images locally (unless `--no-build`)
3. Pushes built images to cluster machines via Unregistry (no external registry needed)
4. Runs `x-pre_deploy` hooks (migrations etc.) if any
5. Shows an **execution plan** (what will change, on which machines)
6. Waits for confirmation (unless `-y/--yes`)
7. Rolls out new containers one at a time, waits for health/monitor period, removes old ones

Specify a non-default file with `-f`:

```bash
uc deploy -f compose.prod.yaml
uc deploy -f compose.yaml -f compose.prod.yaml    # merge multiple
```

Target a subset of services:

```bash
uc deploy web worker          # only these services
```

### 3. Build from source and deploy in one shot

```yaml title="compose.yaml"
services:
  web:
    build: .
    image: myapp:{{gitsha 7}}
    x-ports:
      - app.example.com:8000/https
```

```bash
uc deploy
```

Uncloud builds the image locally using the image tag template (`myapp:<git-sha>`), pushes it to cluster machines via Unregistry, and rolls it out.

Alternate image tag idioms are covered in the `uncloud-compose` skill (see its `references/extensions.md`).

### 4. Separate build and deploy steps (CI/CD)

```bash
# In CI: build + push only
uc build --push

# Later / on deploy: just roll out, do not rebuild
uc deploy --no-build -y
```

`--no-build` tells `uc deploy` to trust images that already exist on the cluster. `-y` auto-confirms the execution plan — **always pass `-y` in non-interactive contexts**, or set `UNCLOUD_AUTO_CONFIRM=1`.

## `uc deploy` flags (full list)

| Flag | Purpose |
|------|---------|
| `-f, --file` | Compose files (repeatable, default `compose.yaml`) |
| `-p, --profile` | Compose profiles to enable |
| `--no-build` | Do not build images before deploy |
| `--build-pull` | Always pull newer base images before building |
| `--no-cache` | Do not use Docker build cache |
| `--build-arg KEY=VAL` | Build-time variable (repeatable) |
| `--recreate` | Recreate containers even if nothing changed |
| `--skip-health` | Skip monitoring and health checks for emergency deploys (dangerous) |
| `-y, --yes` | Auto-confirm. Required for CI |

Plus inherited `--context`, `--connect`, `--uncloud-config`.

## `uc build` flags

```bash
uc build                         # build all services locally
uc build web                     # build only the 'web' service
uc build --push                  # build and push to all cluster machines
uc build --push -m vps1,vps2     # push only to specific machines
uc build --push-registry         # push to external registries (Docker Hub, etc.)
uc build --deps                  # also build dependencies
uc build --check                 # validate build config without building
uc build --no-cache --pull       # fresh rebuild
uc build --build-arg NODE_ENV=production
```

By default images stay in **local Docker**. `--push` uploads them to the cluster. Use `--push-registry` when the user prefers a public registry flow.

## `uc run` flags (one-off)

```bash
uc run [OPTIONS] IMAGE [COMMAND...]
```

Most common options:

| Flag | Purpose |
|------|---------|
| `-n, --name` | Service name (random if omitted) |
| `-p, --publish` | Port (repeatable, same syntax as `x-ports`) |
| `-e, --env` | Env var `VAR=value` or just `VAR` to pass through from shell |
| `-m, --machine` | Machine names to restrict placement to |
| `--mode` | `replicated` (default) or `global` |
| `--replicas` | Number of replicas for replicated mode |
| `--pull` | `always`, `missing` (default), `never` |
| `-u, --user` | Container user |
| `--cpu` | CPU limit (e.g. `0.5`, `2.25`) |
| `--memory` | Memory limit (bytes, `512m`, `1g`) |
| `--entrypoint` | Override ENTRYPOINT |
| `--privileged` | Privileged mode (dangerous) |
| `--caddyfile` | Custom Caddy snippet (file path) — incompatible with non-host published ports |

Example:

```bash
uc run \
  -n api \
  --replicas 3 \
  -p api.example.com:9000/https \
  -e DATABASE_URL \
  -e LOG_LEVEL=info \
  --cpu 1 --memory 512m \
  ghcr.io/me/api:1.4.2
```

For anything beyond a single-service sanity check, prefer a compose file + `uc deploy`.

## Rolling deploys, health checks, rollbacks

Uncloud replaces containers one at a time. Per container:

1. Start the new container
2. **Monitor** it for `deploy.update_config.monitor` seconds (default 5s, env `UNCLOUD_HEALTH_MONITOR_PERIOD` overrides the global default)
3. If a `healthcheck` is configured, wait for `healthy`. Transient `unhealthy` during the monitor window is tolerated to allow recovery.
4. Once healthy (or monitor passes without restart), stop the old container

If the new container keeps crashing, or the healthcheck ends `unhealthy` past the monitor window, Uncloud:

- Rolls **that** container back to the previous image/config
- Fails the deployment
- Keeps partially-rolled-forward containers on the new version (Uncloud does not roll back already-successful containers, so the service may be in a mixed state — fix forward and redeploy)

After a successful deploy, if a container later becomes unhealthy, Uncloud **removes it from Caddy** so traffic doesn't hit it. It does **not** automatically restart or roll it back. Recovery to healthy re-adds it to Caddy.

Retry a failed deploy simply by fixing the issue and running `uc deploy` again. `x-pre_deploy` runs again, so the hook command must be idempotent.

### `--skip-health` is an emergency lever

```bash
uc deploy --skip-health -y
```

Use only when the previous deploy is clearly broken and the user needs to push a fix fast. It ignores the monitor period and healthcheck, so crashing containers go straight to production. Do **not** use it by default.

## Deploying to specific machines

The user can control placement in two places:

1. **Compose-level** (`x-machines` in the service). This is the right place for anything persistent. See `uncloud-compose`.
2. **CLI-level** for image push and one-off runs:

```bash
# Run a single-machine service with uc run
uc run -n monitoring -m vps1 -p 3000/https grafana/grafana

# Push a local image to only some machines
uc image push myapp:latest -m vps1,vps2
```

`x-machines` on a service with volumes keeps the volume sticky to the listed machines, which is critical for databases.

## Global services (one container per machine)

Set `deploy.mode: global` in compose, or pass `--mode global` to `uc run`. Use for:

- The `caddy` service itself
- Log shippers, metrics exporters
- Anything that must run on every host

Combine with `x-machines` to run one container on each of a **subset** of machines (e.g., ingress nodes only).

## Pull policies and private registries

Compose `pull_policy` values:

| Value | Behavior |
|-------|----------|
| `always` | Pull every deploy |
| `missing` (default) | Pull only if not cached on the machine |
| `never` | Never pull. Required for images you push with `uc image push` |

Private registry login: Docker credentials on each **cluster machine** need to have access to the registry. SSH in and run `docker login <registry>` on each machine, or bake a credentials file into your machine provisioning.

## Pushing local images (air-gapped or private-only)

When the cluster cannot reach the registry (air-gapped, or image only exists on the developer's laptop):

```bash
# Push from local Docker to cluster machines over Unregistry
uc image push myapp:latest

# Specific machines only
uc image push myapp:latest -m vps1

# Specific platform (multi-arch builds)
uc image push myapp:latest --platform linux/amd64
```

Then in compose:

```yaml
services:
  web:
    image: myapp:latest
    pull_policy: never
```

And deploy:

```bash
uc deploy
```

Verify images landed with `uc images` (supports filters like `uc images "myapp:1.*" -m vps1`).

## Targeting a context in a deploy

Three ways, in increasing precedence:

1. `x-context: prod` inside `compose.yaml` (best — travels with the file)
2. `--context prod` on the CLI
3. `--connect user@host` to skip the config entirely

```bash
# From file
uc deploy

# Override from CLI
uc deploy -c prod

# Direct (CI without a config file)
UNCLOUD_CONNECT=root@203.0.113.10 uc deploy -y
```

## CI/CD recipe (GitHub Actions shaped)

```yaml
- name: Install uncloud CLI
  run: curl -fsS https://get.uncloud.run/install.sh | sh

- name: Deploy to prod
  env:
    UNCLOUD_CONNECT: root@${{ secrets.UNCLOUD_HOST }}
    UNCLOUD_AUTO_CONFIRM: "1"
  run: |
    mkdir -p ~/.ssh
    echo "${{ secrets.SSH_KEY }}" > ~/.ssh/id_ed25519
    chmod 600 ~/.ssh/id_ed25519
    uc deploy -f compose.yaml -f compose.prod.yaml
```

Notes:

- `UNCLOUD_CONNECT` skips the config file so the runner doesn't need to manage `~/.config/uncloud/config.yaml`.
- `UNCLOUD_AUTO_CONFIRM=1` is the env-var equivalent of `-y`. Either works.
- For private registries, log in on the cluster machines, not in the runner.
- If the image should be tagged by Git SHA, the compose file does it via `image: myapp:{{gitsha 7}}`. No custom CI scripting needed.

## Deploy config changes only

If the user just wants to redeploy with a new env var or scaling number and no new image:

```bash
uc deploy --no-build
```

To force-recreate containers even when nothing changed (cycling a flaky service):

```bash
uc deploy --recreate
```

## Common gotchas

- **`uc deploy` prompting in CI**: missing `-y` or `UNCLOUD_AUTO_CONFIRM=1`. The deploy will hang.
- **"image not found on machine"**: forgot `pull_policy: never` after `uc image push`, or pushed to only some machines and deployed elsewhere. Run `uc images` to verify.
- **Healthcheck failing on new version**: container rolled back, deployment marked failed. Fix forward and redeploy. Do **not** reach for `--skip-health` first.
- **Pre-deploy hook failing**: check `uc logs <service>` for the hook container (it is kept around on failure). Common cause: missing DATABASE_URL in the hook env because the service's `env_file` wasn't picked up. Fix the env then retry.
- **Single-replica service with a volume**: default update order is `stop-first`, so there's a short downtime window. Override to `start-first` only if the app handles concurrent writes (see `uncloud-compose`).
- **`uc build` with `--push-registry`**: the cluster still needs credentials to pull the image. If the registry is private, log in on the machines.
- **`x-context` mismatch**: deploy fails with "context mismatch" or silently goes to the wrong cluster. Align `x-context`, `--context`, and the user's `current_context`.
- **Two services on the same hostname**: only one wins, the other is skipped by Caddy as an "ambiguous site". `uc caddy config` shows the error comment.

## References in this skill

- `references/commands.md` — full flag reference for `uc deploy`, `uc build`, `uc run`, `uc image push`, `uc images`
- `references/rolling.md` — details on rolling deployment, health monitoring, retries, and rollback behavior

Read the references when you need an exact flag or a nuanced answer. Otherwise the body of this SKILL.md is sufficient.
