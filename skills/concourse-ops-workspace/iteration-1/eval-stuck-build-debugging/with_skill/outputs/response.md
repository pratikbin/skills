# Debugging a Stuck `deploy-staging` Build

You have build `#147` (id `2351`) in `payments/deploy-staging` that has been in `started` state for 47 minutes with no log output for the last 30. Here is the exact sequence of commands to run, in order, and what each one tells you.

---

## Step 1 — Confirm the build is still alive and watch live output

```bash
fly -t prod watch -j payments/deploy-staging -b 147
```

**What it tells you:** Attaches to the live log stream for build 147. If `apply-tofu` is genuinely still working (Terraform is just quiet during a large apply), new lines will eventually appear here. If the stream is completely silent for another few minutes after you attach, that is your signal the process is likely hung, not merely slow.

Do **not** abort yet — this is purely observational and does not disturb the running container.

---

## Step 2 — Check worker health

```bash
fly -t prod workers
```

**What it tells you:** Lists every registered worker, its state (`running`, `stalled`, `landed`, `retiring`), container count, and volume count. You are looking for:

- The worker that owns build 147's container. If it shows `stalled`, the worker's heartbeat has stopped — the build is effectively a zombie. That means it is safe to abort.
- Any worker at or near its container/volume limit (`CONCOURSE_MAX_ACTIVE_CONTAINERS_PER_WORKER`, default 250). A saturated worker can cause tasks to appear frozen while they are actually queued.
- All workers missing entirely — means the ATC has no place to run anything and the build will never make progress.

---

## Step 3 — Intercept into the running container (non-destructive inspection)

```bash
fly -t prod intercept -j payments/deploy-staging -b 147 -s apply-tofu
```

**What it tells you:** Opens an interactive shell **inside the container that is currently running the `apply-tofu` step**, without interrupting it. The step's own process keeps running in the foreground; you get a second shell alongside it.

Once inside, run:

```bash
# See what processes are actually running
ps aux

# Check if the tofu/terraform process is alive and consuming CPU
top -bn1 | head -20

# Look at open file descriptors / network connections for the tofu process
# (get the PID from ps aux first, e.g. PID=42)
ls -la /proc/<PID>/fd
cat /proc/<PID>/net/tcp   # or: ss -tnp
```

**Interpretation:**

| What you see | What it means |
|---|---|
| `tofu apply` process is running, CPU > 0 | Still working — a provider API call or a slow resource is just taking time. Do **not** abort. |
| `tofu apply` process is running, CPU = 0 for many minutes | Hung waiting on something (lock, network, provider). Likely safe to abort. |
| No `tofu` / `terraform` process at all | Process already exited; something in Concourse's log collection is stuck. Abort is safe. |
| `intercept` itself times out or errors | The worker is unreachable — confirm with `fly workers`. |

If you see the process is live and working, exit the intercept shell (`exit` or `Ctrl-D`) — the step continues unaffected.

---

## Step 4 — Check for a stalled or missing worker (if intercept failed)

If step 3 gave you a connection error or the worker showed `stalled` in step 2:

```bash
fly -t prod prune-worker -w <worker-name>
```

Or to prune all stalled workers at once:

```bash
fly -t prod prune-worker --all-stalled
```

**What it tells you / does:** Removes the stalled worker record from the ATC database. The build will transition to `errored` because its container is gone. You can then re-trigger safely. Note: pruning a worker does **not** abort the build automatically — you still need step 5 if the build stays in `started`.

---

## Step 5 — Abort the build (only if you have confirmed it is dead)

Abort only after you have evidence from steps 1–4 that the build is not making progress:

```bash
fly -t prod abort-build -j payments/deploy-staging -b 147
```

**What it does:** Sends a termination signal to the step's process inside the container. Concourse marks the build `aborted`. The container is garbage-collected after `CONCOURSE_GC_FAILED_GRACE_PERIOD` (default 5 minutes).

**Important — Terraform state:** `tofu apply` / `terraform apply` writes state at the end of a successful apply, not incrementally. If the process was mid-apply when aborted, the state file may be left with a lock. After aborting, check your Terraform backend (S3 + DynamoDB, GCS, Terraform Cloud, etc.) for a dangling state lock and release it manually before re-triggering:

```bash
# Example for S3+DynamoDB backend
tofu force-unlock <lock-id>
# or via AWS CLI if DynamoDB lock:
aws dynamodb delete-item --table-name <lock-table> --key '{"LockID":{"S":"<lock-id>"}}'
```

---

## Decision summary

```
fly watch -b 147               → Is the process logging? Yes → wait. No → continue.
    ↓
fly workers                    → Is the worker healthy? Stalled → prune, then abort.
    ↓
fly intercept -s apply-tofu   → Is the OS process alive? CPU > 0 → wait. CPU = 0 / missing → abort.
    ↓
fly abort-build -b 147        → Only if confirmed stuck.
    ↓
Release Terraform state lock   → Before re-triggering.
```

---

## One thing to add to your pipeline going forward

Add a `timeout:` to the `apply-tofu` task so Concourse self-aborts if it runs over a threshold, rather than hanging indefinitely:

```yaml
- task: apply-tofu
  timeout: 30m
  config:
    ...
```

This prevents the next occurrence from requiring manual intervention.
