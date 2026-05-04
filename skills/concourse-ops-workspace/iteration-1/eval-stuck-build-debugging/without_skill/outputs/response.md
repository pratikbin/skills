# Debugging a Stuck Concourse CI Build: Step-by-Step

Your `deploy-staging` job (build #2351) has been running for 47 minutes with no log output for 30 of those minutes. Here's how to investigate without touching the build, and how to abort safely if needed.

---

## Phase 1: Observe Without Disturbing

### Step 1 — Watch the live build log

```bash
fly -t prod watch -j payments/deploy-staging
```

This streams the live output of the currently running build. If the `apply-tofu` step is genuinely still working, you might see occasional heartbeat lines. If nothing appears for another few minutes, that confirms the process is silent (which could mean it's waiting on a lock, a provider API call, or is truly hung).

**What it tells you:** Whether any new log output is being produced right now.

---

### Step 2 — Check the specific build by ID

```bash
fly -t prod watch -b 2351
```

Same as above but pinned to build ID `2351`. Useful if another build has started on the same job since you ran `fly builds`. Gives you a stable reference to exactly the run you're investigating.

**What it tells you:** Confirms you're watching the right build, not a newer one.

---

### Step 3 — Inspect the build steps and their state

```bash
fly -t prod builds -j payments/deploy-staging --count 1
```

You already have this output, but run it again to see if the status has changed (`started` → `failed` → `succeeded`). If the status flipped without you doing anything, the process may have just been slow.

**What it tells you:** Current status of the build at this moment.

---

### Step 4 — Check what workers are available and healthy

```bash
fly -t prod workers
```

This lists all registered workers with their state: `running`, `stalled`, `retiring`, or `landed`. A `stalled` worker is a common cause of builds appearing frozen — the worker lost its heartbeat to the ATC but the task process may still be alive on it.

**What it tells you:** Whether the worker handling this build has gone stalled or disappeared. If you see a stalled worker, that's likely your culprit.

---

### Step 5 — Find which worker is running this build

```bash
fly -t prod intercept -j payments/deploy-staging
```

This opens an interactive shell inside the running container of the active step. If `apply-tofu` is your stuck step, you'll land inside that container.

Once inside, you can:

```bash
# See what the tofu/terraform process is doing
ps aux

# Check if the process is alive and what syscall it's blocked on (Linux)
cat /proc/$(pgrep tofu)/status

# Check for statelock files (common with Terraform/OpenTofu S3 backends)
ls -la .terraform/
```

**What it tells you:** Whether the `tofu apply` process is actually running, what it's doing at the OS level, and whether it's waiting on a network call or a state lock.

> **Note:** `fly intercept` works on the currently active step. If the task container has already exited silently (e.g., process died but Concourse didn't detect it), intercept will fail or give you a shell in a different step.

---

### Step 6 — Check for Terraform/OpenTofu state locks externally

This is outside Concourse but critical. If your `apply-tofu` step uses a remote backend (S3 + DynamoDB, GCS, etc.), the state file is probably locked. Check your backend directly:

**For S3 + DynamoDB (common):**

```bash
# Check DynamoDB lock table
aws dynamodb get-item \
  --table-name <your-lock-table> \
  --key '{"LockID": {"S": "<your-state-path>"}}'
```

**For Terraform Cloud / HCP Terraform:**
Check the workspace run in the UI — it will show a "locked" badge and who/what holds the lock.

**What it tells you:** If there's an active state lock, Tofu is waiting to acquire it (or is holding it while waiting on the provider). This is the most common reason for silent hangs during `apply`.

---

## Phase 2: Diagnose Worker-Side Problems

### Step 7 — Check worker volumes and containers

```bash
fly -t prod volumes
fly -t prod containers
```

`fly volumes` shows task caches and resource volumes per worker. `fly containers` shows currently running containers on each worker.

Look for:
- Containers on a worker that shows as `stalled` in `fly workers`
- Volumes associated with the `payments` pipeline

**What it tells you:** Confirms which worker is holding this build's container and whether that worker is in a healthy state from ATC's perspective.

---

### Step 8 — SSH to the worker (if you have access)

If you have shell access to the Concourse worker nodes, check the container runtime directly:

```bash
# On the worker node — list running containers
sudo runc list
# or if using containerd:
sudo ctr containers list

# Check resource usage of the tofu process
top -p $(pgrep tofu)

# Check network connections from the tofu process (is it waiting on a provider API?)
sudo lsof -p $(pgrep tofu) -i
```

**What it tells you:** Whether the process is consuming CPU/memory (active work) or is in a wait state (blocked on I/O, network, or a lock). A process with 0% CPU for 30 minutes is not doing useful work.

---

## Phase 3: Abort Safely If Needed

If you've confirmed the build is truly hung (worker stalled, process dead, or lock held by a zombie), abort it:

### Step 9 — Abort the build

```bash
fly -t prod abort-build -j payments/deploy-staging -b 2351
```

**Important state considerations before aborting:**

1. **Check if Tofu partially applied.** After abort, run `tofu plan` (outside Concourse) against your staging state to see what was applied vs. what wasn't. A partial apply is recoverable but you need to know your current state.

2. **Release the state lock manually if needed.** If the state lock wasn't released after abort:
   ```bash
   tofu force-unlock <lock-id>
   ```
   Get the lock ID from the DynamoDB table or from the error message when you next try to run `tofu plan`.

3. **Do not re-trigger the pipeline immediately.** Verify the state file reflects reality first. A second `apply` on a partially-applied state can create duplicate resources or conflicts.

---

## Summary: Decision Tree

```
fly watch -j payments/deploy-staging
  │
  ├─ Still producing output → wait, it's working
  │
  └─ Silent
        │
        ├─ fly workers → stalled worker
        │     └─ Worker is dead → abort build, check worker health
        │
        ├─ fly intercept → process alive
        │     └─ Check lsof/strace → waiting on provider API or lock
        │           └─ Check backend lock table → force-unlock if orphaned
        │
        └─ fly intercept → fails / process dead
              └─ Build is hung → abort, inspect state file, re-run
```

---

## Quick Reference: Commands in Order

| Order | Command | Purpose |
|-------|---------|---------|
| 1 | `fly -t prod watch -b 2351` | Live log stream — is anything happening? |
| 2 | `fly -t prod workers` | Worker health — any stalled? |
| 3 | `fly -t prod containers` | Which worker holds this container? |
| 4 | `fly -t prod intercept -j payments/deploy-staging` | Shell into running container |
| 5 | `ps aux` (inside container) | Is the tofu process alive? |
| 6 | Check backend lock table (AWS/GCS) | Is the state file locked? |
| 7 | `fly -t prod abort-build -j payments/deploy-staging -b 2351` | Abort if confirmed dead |
| 8 | `tofu force-unlock <lock-id>` | Release orphaned state lock after abort |
