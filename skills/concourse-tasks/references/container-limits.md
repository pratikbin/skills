# container-limits.md

Cap CPU and memory for a task container. Default: unbounded.

## Schema

```yaml
# In task.yml
container_limits:
  cpu: 512              # millicores. 1000 = 1 vCPU. 0 = no limit (default)
  memory: 536870912     # bytes. also accepts suffix: 512m, 1g, 2g. 0 = no limit
```

Also settable at the **task step** level in pipeline.yml (overrides task.yml value):

```yaml
# pipeline.yml
- task: heavy-compile
  file: ci/tasks/compile.yml
  container_limits:
    cpu: 2000           # 2 vCPU
    memory: 4g
```

Step-level `container_limits` takes precedence over task.yml `container_limits`. Concourse operators can also set cluster-wide defaults via tuning config.

## Units

**CPU** — millicores (thousandths of a CPU core):
- `500` = 0.5 vCPU
- `1000` = 1 vCPU
- `4000` = 4 vCPU

**Memory** — bytes, or use suffixes:
- `536870912` = 512 MiB (explicit bytes)
- `512m` = 512 MiB
- `1g` = 1 GiB
- `4g` = 4 GiB

## When to set limits

**Set limits when:**
- Cluster has multiple teams sharing workers. Fairness: one runaway build shouldn't starve others.
- Task is known to be memory-hungry (e.g., JVM build, webpack, Go builds with CGO).
- Task has historically OOM-killed workers.
- Running parallel test shards — limit each shard so worker isn't overwhelmed.

**Don't bother when:**
- Single-team Concourse deployment.
- Task is fast and light (lint, shell script, echo).
- Worker is dedicated to this job.

## Example — memory-hungry Go build

```yaml
# ci/tasks/build.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: golang
    tag: "1.22"
  version:
    digest: "sha256:abc123..."

inputs:
  - name: source

outputs:
  - name: bin

container_limits:
  cpu: 2000       # 2 vCPU
  memory: 2g      # Go builds + modules can spike to 1.5 GB

run:
  path: bash
  args:
    - -ec
    - |
      cd source
      go build -o ../bin/app ./cmd/app
```

## Example — OOM-prone test suite

```yaml
# pipeline.yml — override limit per job
- task: run-tests
  file: ci/tasks/test.yml
  container_limits:
    cpu: 1000
    memory: 3g          # test suite known to leak in one dependency
```

## Interaction with worker capacity

Worker has a fixed amount of CPU and memory. Container limits are enforced by the Linux cgroup subsystem:
- CPU limit is a **throttle** (task gets less CPU time, runs slower, not killed).
- Memory limit is a **hard cap** (task gets OOM-killed if it exceeds the limit).

OOM kill → task exit code non-zero → task step fails. Symptom: "Killed" in logs, or silent exit 137.

If `memory` limit is too low: tasks fail intermittently. Raise the limit or optimize memory use.
If `cpu` limit is too low: tasks run slower but complete. Affects wall-clock time, not correctness.

## Tradeoff

Lower limits → more tasks can run in parallel on the same worker → higher throughput for the cluster.
But: any task that needs more resources than its limit will retry (OOM) or run slow (CPU throttle).

Set limits based on observed peak usage, not worst-case theoretical. Use `fly intercept` to inspect `/proc/meminfo` or run the task under `valgrind`/`heaptrack` to measure.

## Gotchas

- `memory: 0` means unlimited, not zero. Don't set `0` thinking it means "no memory".
- CPU limits affect the **whole container** including the shell, not just the main process.
- Concourse operator can set global defaults. Your task-level limits still take effect and are enforced on top of defaults.
- Cluster-wide `max_memory_limit` set by ops team can cap what tasks can request.

## See also

- `schema.md` — container_limits in full task config
- `debugging.md` — `fly intercept` to inspect container resource usage
- `anti-patterns.md` — unlimited containers on shared workers
