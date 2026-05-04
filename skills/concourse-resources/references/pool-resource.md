# pool-resource.md — `pool` resource type schema and patterns

Coordinate exclusive access to shared resources using a git-backed lock pool. Each lock is a file in the repo.

---

## Schema

Declare the resource type first (not built-in):

```yaml
resource_types:
  - name: pool
    type: registry-image
    source:
      repository: concourse/pool-resource
      tag: "1.1.3"
```

```yaml
resources:
  - name: staging-env
    type: pool
    source:
      uri: git@github.com:example/locks.git   # required; SSH or HTTPS git repo
      branch: master                           # required; branch that holds the lock files
      pool: staging                            # required; subdirectory name under the branch
      private_key: ((git.locks-deploy-key))    # required for SSH URI
      username: ((git.username))               # optional; for HTTPS auth
      password: ((git.password))               # optional; for HTTPS auth
      retry_delay: 10s                         # optional; how long to wait between claim retries
```

The lock repo structure:

```
staging/
  unclaimed/
    env-a        # empty file — available lock
    env-b
  claimed/
    env-c        # file contains the claimant's metadata
```

Pre-populate the `unclaimed/` directory with one empty file per lock before using the resource.

---

## Operations via `put` params

```yaml
# Acquire a random unclaimed lock
- put: staging-env
  params:
    acquire: true

# Acquire a specific named lock
- put: staging-env
  params:
    claim: env-a

# Release a previously claimed lock (lock dir from a prior get/put)
- put: staging-env
  params:
    release: staging-env        # path to the directory output by the prior get/put

# Add a new lock file to unclaimed/
- put: staging-env
  params:
    add: new-lock-dir           # directory whose name becomes the lock name
    add_claimed: false          # if true, add to claimed/ instead of unclaimed/

# Remove a lock file from the pool
- put: staging-env
  params:
    remove: staging-env         # path to the lock directory to remove entirely
```

### `get` step — read the currently claimed lock

```yaml
- get: staging-env
```

Fetches the lock directory. The lock filename is in `staging-env/name`. Lock metadata (if any) is in `staging-env/metadata`.

---

## Examples

### Claim/release pattern around a deploy job

```yaml
resources:
  - name: staging-lock
    type: pool
    source:
      uri: git@github.com:example/locks.git
      branch: master
      pool: staging
      private_key: ((git.locks-key))

  - name: app-src
    type: git
    source:
      uri: https://github.com/example/app.git
      branch: main

jobs:
  - name: deploy-staging
    plan:
      - get: app-src
        trigger: true
        passed: [test]

      - put: staging-lock          # claim: blocks until a lock is available
        params:
          acquire: true

      - task: deploy
        # deploys the app; uses staging-lock/name to know which env

      - put: staging-lock          # release: always run, even on failure
        params:
          release: staging-lock
    on_failure:
      put: staging-lock
      params:
        release: staging-lock
```

The `on_failure` release ensures the lock is freed even if deploy fails. Without it, a failed job leaves the lock claimed forever.

---

### Manual approval gate using a pre-claimed lock

```yaml
resources:
  - name: deploy-gate
    type: pool
    source:
      uri: git@github.com:example/locks.git
      branch: master
      pool: deploy-approval

# Pre-populate with a single lock in claimed/ (manually approve by moving to unclaimed/)
# locks/deploy-approval/claimed/gate  — initial state: blocked

jobs:
  - name: deploy-prod
    plan:
      - get: deploy-gate       # blocks until someone moves "gate" to unclaimed/
        trigger: true
      - put: deploy-gate
        params:
          acquire: true        # claim it so only one deploy runs at a time
      - task: deploy-prod
      - put: deploy-gate
        params:
          release: deploy-gate
```

An operator moves the lock file from `claimed/` to `unclaimed/` to approve a deploy. After the job runs, the lock is re-released for the next approval cycle.

---

### Finite license pool — only 3 concurrent test runs

```yaml
# locks/load-test/unclaimed/ has files: slot-1, slot-2, slot-3

resources:
  - name: load-test-slot
    type: pool
    source:
      uri: git@github.com:example/locks.git
      branch: master
      pool: load-test
      private_key: ((git.locks-key))

jobs:
  - name: run-load-test
    plan:
      - put: load-test-slot
        params:
          acquire: true           # blocks until one of 3 slots is free
      - task: load-test
      - put: load-test-slot
        params:
          release: load-test-slot
```

---

## Gotchas

- Every lock operation (claim, release, add, remove) is a git commit to the locks repo. Expect 2–5 seconds of latency per operation. Not suitable for sub-second coordination.
- Under high parallelism, multiple jobs competing for the same pool will git-push-conflict. The resource retries automatically with `retry_delay` (default 10s), but heavy contention degrades performance.
- Always release the lock in `on_failure` and `ensure` hooks. A lock left claimed by a failed build blocks all other consumers indefinitely.
- The `release` param value must be the **path to the output directory** from the prior `get` or `put` that claimed the lock, not the lock name string.
- `add_claimed: false` (default) adds a new lock to `unclaimed/`. Use `add_claimed: true` when pre-seeding a lock in a claimed state (e.g., for approval gates).
- The locks repo should be dedicated to lock files. Mixing it with source code creates noise and slows down claim/release operations.

---

## See also

- [versioning.md](versioning.md) — `trigger: true` on pool get for approval gates
- [anti-patterns.md](anti-patterns.md) — pool contention under load
- [core-types.md](core-types.md) — when pool vs other serialization approaches
