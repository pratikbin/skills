# Rolling deployments, health, rollback

## Sequence for a 3-replica service (default `start-first`)

1. Start new container #1
2. Wait for new #1 to pass monitor period + healthcheck
3. Stop and remove old container #1
4. Start new container #2
5. Wait for new #2 to pass monitor period + healthcheck
6. Stop and remove old container #2
7. Start new container #3
8. Wait for new #3 to pass monitor period + healthcheck
9. Stop and remove old container #3

At every step, at least 3 containers are serving traffic. Uncloud never takes capacity below the target.

## `start-first` vs `stop-first`

| Order | Behavior | Default for |
|-------|----------|-------------|
| `start-first` | Start new, wait, then stop old. No downtime. Temporarily exceeds target count | Stateless services |
| `stop-first` | Stop old, then start new. Brief downtime per container | Services with volumes (avoids two replicas fighting over the same data) |

Override with `deploy.update_config.order: start-first` in compose. Only do this for volume-backed services when the app handles concurrent writes safely (SQLite WAL mode, shared-nothing workers, etc.).

## Monitor period

After each new container starts, Uncloud watches it for `monitor` seconds:

- Default: **5 seconds**
- Override per service: `deploy.update_config.monitor: 10s`
- Override globally: `UNCLOUD_HEALTH_MONITOR_PERIOD=10s` environment variable on the machine running `uncloudd`

Set to `0s` to skip monitoring entirely (risky, prefer a healthcheck).

During the monitor window:

- If the container crashes → rollback + fail deploy
- If the container runs continuously → deploy moves on to the next container

## Health checks

Configure with standard Compose `healthcheck`:

```yaml
services:
  app:
    image: myapp
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8000/health"]
      interval: 5s
      retries: 3
      start_period: 10s
      start_interval: 1s
```

Behavior during deploy:

- Container becomes `healthy` before monitor window ends → deploy moves on **early**
- Container is still `unhealthy` after monitor window → rollback + fail deploy
- Container is transiently `unhealthy` during monitor window → tolerated

Post-deploy (after successful rollout):

- If a container later goes `unhealthy`, Uncloud **removes** it from Caddy's upstream list so traffic stops going to it
- Uncloud does **not** auto-restart or roll it back
- Docker's `restart:` policy still applies — use `restart: unless-stopped` for flaky apps
- When the container recovers and becomes `healthy`, Uncloud **re-adds** it to Caddy

## `--skip-health` (emergency)

`uc deploy --skip-health -y` skips both monitor period and healthcheck gating. Use it only when:

- The previous deploy is clearly broken
- You are pushing a known-good fix
- You are OK with crashing containers going straight into rotation

Do not reach for it as a first response. It hides the exact problem you need to see.

## Retry after failure

A failed deploy leaves:

- Already-rolled-forward containers on the **new** version
- The container that failed rolled back to the **old** version
- The pre-deploy hook container (if any) kept around for inspection

To retry: fix the root cause and run `uc deploy` again. The pre-deploy hook runs again, so it must be idempotent. Most migration tools already are.

## Rollback to a previous image

Uncloud does not have an explicit `uc rollback` command. To roll back:

1. Edit `compose.yaml` to pin the previous image tag (for example, replace `{{gitsha 7}}` with the known-good SHA)
2. Run `uc deploy`

Git makes this trivial if the compose file is committed. This is another reason to put compose in version control and use image tag templates that bake the Git SHA into the tag.

## Single-replica services

With one replica, there is no way to update without at least a brief interruption:

- `stop-first` (default for volume-backed): stop old → start new → wait healthy. Downtime = startup time.
- `start-first`: start new (which conflicts with old on shared resources unless they tolerate it) → wait healthy → stop old.

For zero downtime on a single-replica service, the app must be OK with two instances existing briefly at the same time, and the underlying storage must handle concurrent access. For most apps, just scale to 2 replicas.
