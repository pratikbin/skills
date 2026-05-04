# Debugging stuck builds, checks, and workers

First-aid for the most common Concourse operational problems.

## Stuck checks

Symptom: resource shows "checking" forever; `concourse_lidar_check_queue_size` grows; build triggers never fire.

### Diagnose

```bash
# Force a check and watch output
fly -t prod check-resource -r my-pipeline/my-resource

# Is it queued or running?
# Prometheus: concourse_lidar_check_queue_size vs concourse_lidar_checks_started_total

# Look at web node logs for lidar errors
# grep for "check" or the resource name in ATC logs
```

### Fix

```bash
# Force-clear all cached versions for the resource (re-check from scratch)
fly -t prod clear-resource-cache -r my-pipeline/my-resource

# If check is permanently stuck, pause and unpause the resource to force GC
fly -t prod pause-pipeline -p my-pipeline
fly -t prod unpause-pipeline -p my-pipeline
```

If checks still fail, look at the check container. It may be stuck due to a hung network call or a bad resource type image. Intercept into it:

```bash
fly -t prod intercept -j my-pipeline/check -s check
# Note: check steps appear as "check" pseudo-step in intercept
```

If the resource type image is corrupt or unreachable, update the `type` source or pin a known-good digest.

## Stuck builds

Symptom: build shows "running" forever; no log output; worker looks healthy.

### Diagnose

```bash
# Stream the build to see if there's any output
fly -t prod watch -j my-pipeline/my-job

# Intercept into the stuck step's container
fly -t prod intercept -j my-pipeline/my-job -s build

# Intercept a specific build number
fly -t prod intercept -j my-pipeline/my-job -b 42 -s build
```

Inside the intercepted container: check running processes (`ps aux`), network connections (`ss -tnp`), open files (`lsof`). Common culprits: hung git clone, hung apt-get, process waiting on stdin.

### Fix

```bash
# Abort the stuck build
fly -t prod abort-build -j my-pipeline/my-job -b 42
```

After aborting, the container is GC'd after `CONCOURSE_GC_FAILED_GRACE_PERIOD` (default 5m). Increase this if you need more time to investigate before the container disappears.

### Container TTL gotchas

- `fly intercept` opens a shell into the container. The container lives as long as there is an active session OR until GC runs.
- If the build is still running, GC won't touch the container. Safe to intercept.
- If the build aborted/failed, you have `CONCOURSE_GC_FAILED_GRACE_PERIOD` before GC removes the container.
- One-off `fly execute` containers are also GC'd after the build ends. Use `--include-artifact` / `--output` to extract outputs before GC.

## Missing / stalled workers

Symptom: workers disappear from `fly workers`; builds queue forever with "pending" status; `fly workers` shows workers in `stalled` state.

### Diagnose

```bash
# List all workers and their state
fly -t prod workers

# States: running | stalled | landed | retiring
# "stalled" = worker missed heartbeat, ATC considers it gone
```

### Fix

```bash
# Remove a specific stalled worker (allows new containers to schedule)
fly -t prod prune-worker -w worker-name

# Remove ALL stalled workers at once
fly -t prod prune-worker --all-stalled
```

After pruning, restart the worker process. It will re-register with the ATC and get a new heartbeat.

If workers keep going stalled: check network between worker and ATC, firewall rules, and ATC load. The heartbeat interval is `CONCOURSE_WORKER_HEARTBEAT_TTL` (default 2m); workers ping every ~30s.

## Builds queued forever ("pending" never starts)

Symptom: `fly builds` shows build in pending state; no workers assigned.

```bash
# Check available workers
fly -t prod workers

# Check if job requires tagged workers that don't exist
# Look at job's tags: in pipeline config
fly -t prod get-pipeline -p my-pipeline | grep -A5 tags

# Check if there are no workers at all
# OR all workers are at container/volume limits
```

Fixes:
1. If tagged workers missing: add a worker with the required tag or remove the `tags:` constraint.
2. If workers are at limit: increase `CONCOURSE_MAX_ACTIVE_CONTAINERS_PER_WORKER` or add more workers.
3. If placement strategy filters all workers: check `concourse_containers_per_worker` metrics; adjust limits.

## DB lock contention

Symptom: slow web UI, slow scheduling, `concourse_locks_held` metric shows long-held locks, ATC logs show "waiting for lock".

```bash
# Prometheus metric — watch for locks held > a few seconds
# concourse_locks_held{type="Batch"} > 0
# concourse_locks_held{type="DatabaseMigration"} > 0
```

Postgres query to check:
```sql
SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state
FROM pg_stat_activity
WHERE (now() - pg_stat_activity.query_start) > interval '5 seconds';
```

Fixes:
1. Scale up Postgres `work_mem` for complex queries.
2. Reduce `CONCOURSE_LIDAR_MAX_CONCURRENT_CHECKS` — fewer concurrent DB writes.
3. Add Postgres indexes on `builds(team_id, pipeline_id, job_id)` and `resource_config_versions`.
4. Scale Postgres vertically if I/O is the bottleneck.

## Quick-reference decision tree

```
Build stuck running?
  → fly watch → no output → fly intercept → check processes
  → fly abort-build → increase GC_FAILED_GRACE_PERIOD for next time

Check stuck?
  → fly check-resource -r ... (force manual check)
  → fly clear-resource-cache -r ... (reset version history)

Build queued forever?
  → fly workers → any workers up?
    No → prune stalled, restart worker daemons
    Yes → check tags match, check container limits

Worker stalled?
  → fly prune-worker -w name → restart worker
  → fly prune-worker --all-stalled (mass cleanup)
```

## See also

- `references/fly-cli.md` — `fly intercept`, `fly abort-build`, `fly prune-worker`
- `references/perf-tuning.md` — `GC_FAILED_GRACE_PERIOD`, `WORKER_HEARTBEAT_TTL`
- `references/container-placement.md` — placement strategy and worker limits
- `references/observability.md` — metrics for diagnosing queue buildup
