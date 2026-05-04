# Container placement strategies

How Concourse decides which worker runs a build step or resource check. Strategies are chained (comma-separated); each pass filters the candidate worker list.

## Available strategies

### volume-locality

Keeps workers that already have the most input volumes cached locally. Reduces network transfer for large inputs.

- Best for: pipelines that re-use the same inputs (e.g. large Docker images, big git repos).
- Tie-breaks: random if no worker has any volumes.
- Downside: can concentrate load on one worker if all pipelines share the same input.

### fewest-build-containers

From the remaining candidates, picks the worker with the fewest active build containers.

- Best for: even distribution of build load across workers.
- Tie-breaks: random among equal-count workers.
- Use after `volume-locality` to balance ties.

### limit-active-containers

Removes workers that already have >= `CONCOURSE_MAX_ACTIVE_CONTAINERS_PER_WORKER` containers. Acts as a hard cap.

```properties
CONCOURSE_MAX_ACTIVE_CONTAINERS_PER_WORKER=200
```

- Best for: preventing a single overloaded worker.
- Use first in the chain, before locality strategies.

### limit-active-tasks

Removes workers that have >= N concurrently executing task steps.

```properties
CONCOURSE_MAX_ACTIVE_TASKS_PER_WORKER=50
```

More granular than container limits when tasks are long-running.

### limit-active-volumes

Removes workers with >= `CONCOURSE_MAX_ACTIVE_VOLUMES_PER_WORKER` volumes.

```properties
CONCOURSE_MAX_ACTIVE_VOLUMES_PER_WORKER=100
```

Prevents disk exhaustion. Use alongside `limit-active-containers`.

### random

Selects randomly from remaining candidates. Default if no strategy is configured.

- Best for: tiny clusters where every worker is equivalent.
- Defeats volume reuse — avoid as sole strategy on large clusters.

## Chaining

Strategies are applied left to right. Each pass narrows the candidate list. If a pass would eliminate all workers, it is skipped (the list is unchanged).

```properties
# Recommended for most production clusters
CONCOURSE_CONTAINER_PLACEMENT_STRATEGY=volume-locality,fewest-build-containers

# With hard limits to protect workers
CONCOURSE_CONTAINER_PLACEMENT_STRATEGY=limit-active-containers,limit-active-volumes,volume-locality,fewest-build-containers
CONCOURSE_MAX_ACTIVE_CONTAINERS_PER_WORKER=200
CONCOURSE_MAX_ACTIVE_VOLUMES_PER_WORKER=100
```

Example trace with the full chain above:
1. `limit-active-containers` removes workers at >= 200 containers.
2. `limit-active-volumes` removes workers at >= 100 volumes.
3. `volume-locality` keeps only the worker(s) with the most inputs locally.
4. `fewest-build-containers` picks the least-loaded among tied workers.

## Tags

Workers and tasks/resources can have tags. Concourse only considers workers whose tags are a superset of the step's `tags:`.

```yaml
# Pipeline resource — must land on tagged worker
resources:
  - name: internal-registry
    type: registry-image
    source:
      repository: registry.internal.example.com/myapp
    tags: [internal-network]

# Task — must land on GPU worker
jobs:
  - name: train
    plan:
      - task: train-model
        config:
          platform: linux
          run:
            path: python
            args: [train.py]
        tags: [gpu]
```

Tags are AND conditions. A step with `tags: [internal-network, gpu]` requires a worker with both tags. Tags filter before any placement strategy runs.

## When to use which

| Situation | Strategy |
|-----------|----------|
| Small cluster, < 5 workers | `random` (default) |
| Large inputs re-used across builds | `volume-locality,fewest-build-containers` |
| Workers getting overwhelmed | `limit-active-containers,volume-locality,fewest-build-containers` |
| Disk full on workers | `limit-active-volumes,volume-locality,fewest-build-containers` |
| Long-running tasks | `limit-active-tasks,volume-locality,fewest-build-containers` |

## Gotchas

- `random` as the sole strategy defeats volume caching. Builds repeatedly pull large images from scratch.
- If `limit-active-containers` would eliminate all workers, it is skipped — the cluster keeps running but health is degraded.
- Tags must match exactly. A worker with `tags: [gpu]` does NOT satisfy `tags: [gpu, internal-network]`.
- Placement strategy is a web node (ATC) setting, not per-pipeline.

## See also

- `references/perf-tuning.md` — `CONCOURSE_CONTAINER_PLACEMENT_STRATEGY` in context
- `references/observability.md` — `concourse_containers_per_worker` metric
