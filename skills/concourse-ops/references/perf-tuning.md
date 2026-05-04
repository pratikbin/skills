# Performance tuning

Key env vars and strategies for scaling Concourse. Always collect metrics before tuning.

## Runtime selection

```properties
# containerd (default v8+, recommended)
CONCOURSE_RUNTIME=containerd

# guardian (Garden-runC, older default)
CONCOURSE_RUNTIME=guardian
```

`containerd` has lower overhead and better OCI support. Guardian is legacy; only use if your worker OS doesn't support containerd.

## Lidar (resource checking)

Lidar is the subsystem that enqueues resource version checks.

```properties
# How often lidar scans for resources due a check (default: 10s)
CONCOURSE_LIDAR_SCANNING_INTERVAL=10s

# Max concurrent checks running at once across the cluster (default: 32)
CONCOURSE_LIDAR_MAX_CONCURRENT_CHECKS=64

# Timeout for a single check (default: 1m)
CONCOURSE_LIDAR_CHECK_TIMEOUT=1m
```

Large clusters with many resources: increase `CONCOURSE_LIDAR_MAX_CONCURRENT_CHECKS`. If checks are queuing (`concourse_lidar_check_queue_size` metric grows), increase this or reduce check frequency via `check_every` on resources.

## Build scheduling and execution

```properties
# How often the build scheduler runs (default: 10s)
CONCOURSE_BUILD_TRACKER_INTERVAL=10s

# Max builds the ATC will track simultaneously (affects memory on web)
# No hard limit env var; scale horizontally instead.
```

## Garbage collection

```properties
# How often GC runs (default: 30s)
CONCOURSE_GC_INTERVAL=30s

# Retain failed build containers for debugging (default: 5m)
CONCOURSE_GC_FAILED_GRACE_PERIOD=5m

# Missing workers: how long before marking stalled (default: 1m timeout for heartbeat)
CONCOURSE_WORKER_HEARTBEAT_TTL=2m
```

Increase `CONCOURSE_GC_FAILED_GRACE_PERIOD` when debugging failing builds — gives more time to `fly intercept` into them.

## Container placement

```properties
# Recommended chain for most clusters
CONCOURSE_CONTAINER_PLACEMENT_STRATEGY=volume-locality,fewest-build-containers

# Add hard limits if workers get overwhelmed
CONCOURSE_CONTAINER_PLACEMENT_STRATEGY=limit-active-containers,volume-locality,fewest-build-containers
CONCOURSE_MAX_ACTIVE_CONTAINERS_PER_WORKER=250

# Add volume limit too
CONCOURSE_CONTAINER_PLACEMENT_STRATEGY=limit-active-containers,limit-active-volumes,volume-locality,fewest-build-containers
CONCOURSE_MAX_ACTIVE_CONTAINERS_PER_WORKER=200
CONCOURSE_MAX_ACTIVE_VOLUMES_PER_WORKER=100
```

Full strategy reference: `references/container-placement.md`.

## Postgres tuning notes

Concourse is postgres-heavy. Basic guidance:

| Parameter | Recommendation |
|-----------|---------------|
| `max_connections` | Set to `(web_nodes * 50) + 10`. Too high → OOM. |
| `shared_buffers` | 25% of postgres RAM. |
| `work_mem` | 4–16 MB. Concourse runs complex queries. |
| `effective_cache_size` | 50–75% of total RAM. |
| `checkpoint_completion_target` | 0.9 |

Add indexes if you see slow queries on `builds` or `resource_config_versions` tables — check `pg_stat_statements`.

Use `CONCOURSE_POSTGRES_MAX_OPEN_CONNS` (default 32) and `CONCOURSE_POSTGRES_MAX_IDLE_CONNS` (default 5) on the web node to bound postgres connection usage.

## Worker sizing

General guidance (not hard limits):

| Workload | Workers | CPU | RAM |
|----------|---------|-----|-----|
| Small (< 50 concurrent builds) | 2–3 | 4 core | 8 GB |
| Medium (50–200 concurrent builds) | 4–8 | 8 core | 16 GB |
| Large (200+ concurrent builds) | 8+ | 16 core | 32 GB |

Workers store volumes on disk. Provision at least 100 GB per worker; 200+ GB for image-heavy workflows. Monitor `concourse_volumes_per_worker` and `concourse_containers_per_worker` metrics.

## Gotchas

- Increasing `CONCOURSE_LIDAR_SCANNING_INTERVAL` above 30s makes resources feel sluggish. Decrease `check_every` on hot resources instead.
- Too many concurrent checks (`CONCOURSE_LIDAR_MAX_CONCURRENT_CHECKS` too high) can starve workers on clusters with limited worker capacity.
- `CONCOURSE_GC_FAILED_GRACE_PERIOD` only helps if the worker is still alive. If the worker died, the container is gone.
- Postgres `max_connections` exhaustion shows as `pq: sorry, too many clients already` in web logs. Lower `CONCOURSE_POSTGRES_MAX_OPEN_CONNS` or scale postgres with pgBouncer.

## See also

- `references/container-placement.md` — placement strategy details
- `references/observability.md` — metrics to track before/after tuning
- `references/debugging-stuck.md` — stuck builds, stuck checks
