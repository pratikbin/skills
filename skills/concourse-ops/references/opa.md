# OPA policy integration

Concourse can consult an Open Policy Agent (OPA) endpoint before allowing certain actions. Enables cluster-wide guardrails.

## Enabling (operator)

```properties
# web node
CONCOURSE_OPA_URL=http://opa.policy.svc.cluster.local:8181/v1/data/concourse/allow
```

The URL must point to a specific OPA package/rule that returns a decision object. Concourse POSTs to this URL; if OPA is unreachable, the action is **allowed by default** (fail-open).

## Decision shape

Concourse expects the OPA rule to return:

```json
{
  "result": {
    "allowed": true,
    "block": false,
    "reasons": []
  }
}
```

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `allowed` | bool | yes | `false` = deny (or warn if `block: false`) |
| `block` | bool | no | `false` = soft denial (warn only, action proceeds) |
| `reasons` | []string | no | Messages shown in the Concourse UI |

If `allowed: false` and `block: true` (or `block` absent): action is denied.
If `allowed: false` and `block: false`: action proceeds with reasons shown as warnings.

## Supported actions

| Action | Triggered by |
|--------|-------------|
| `SetPipeline` | `fly set-pipeline` or `set_pipeline` step |
| `SaveConfig` | Same as SetPipeline |
| `GetConfig` | `fly get-pipeline` |
| `DestroyPipeline` | `fly destroy-pipeline` |
| `PausePipeline` / `UnpausePipeline` | fly pause/unpause |
| `CreateBuild` | `fly trigger-job` |
| `AbortBuild` | `fly abort-build` |
| `PutResource` | `put` step in a build |
| `GetResource` | `get` step in a build |

The full action name is sent in the `input.action` field.

## OPA input shape

```json
{
  "action": "SetPipeline",
  "team": "my-team",
  "pipeline": "my-pipeline",
  "data": {
    "config": { ... }
  },
  "user": {
    "connector": "github",
    "sub": "alice"
  }
}
```

For `SetPipeline`, `data.config` is the full parsed pipeline YAML as a JSON object. Use this to inspect job/resource definitions.

## Example: block pipelines with privileged tasks

```rego
package concourse

default allow = true

# Deny SetPipeline if any task is privileged
deny[reason] {
  input.action == "SetPipeline"
  job := input.data.config.jobs[_]
  step := job.plan[_]
  step.task != ""
  step.config.run.privileged == true
  reason := sprintf("job %s contains a privileged task: %s", [job.name, step.task])
}

allow = false {
  count(deny) > 0
}

reasons = deny
block = true
```

Serve this policy at the OPA endpoint, map the rule to `concourse.allow`.

## Example: warn (not block) on missing resource tags

```rego
package concourse

default allow = true
block = false   # soft enforcement; action proceeds but shows warning

reasons[r] {
  input.action == "SetPipeline"
  resource := input.data.config.resources[_]
  count(resource.tags) == 0
  r := sprintf("resource %s has no tags — consider adding worker affinity", [resource.name])
}
```

## Gotchas

- OPA unreachable = fail-open (action allowed). Monitor OPA availability separately.
- `CONCOURSE_OPA_URL` points to a single rule, not a full OPA server base. Include the full `/v1/data/package/rule` path.
- `set_pipeline` step in a build triggers `SetPipeline` action — OPA sees the child pipeline config too.
- `block` defaults to `true` if absent. Always set it explicitly to avoid accidental hard blocks when iterating on policies.

## See also

- `references/set-pipeline-step.md` — OPA hook triggered by set_pipeline step
- `references/teams-auth.md` — role-based access as complement to OPA
