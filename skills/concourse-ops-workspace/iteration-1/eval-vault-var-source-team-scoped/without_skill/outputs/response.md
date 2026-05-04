# Team-Scoped Vault Var Source for Concourse v8

## The `var_sources` Block

Add this to your `pipeline.yml`:

```yaml
var_sources:
  - name: vault
    type: vault
    config:
      url: https://vault.example.internal
      ca_cert: /etc/ssl/certs/internal-ca.crt
      auth_backend: approle
      auth_params:
        role_id: ((vault-bootstrap:role_id))
        secret_id: ((vault-bootstrap:secret_id))
      path_prefix: secret/data/concourse/payments
      namespace: ""  # omit if not using Vault Enterprise namespaces
```

Then in any job step, reference secrets like this:

```yaml
jobs:
  - name: run-migrations
    plan:
      - task: migrate
        config:
          platform: linux
          image_resource:
            type: registry-image
            source:
              repository: flyway/flyway
          params:
            DB_PASSWORD: ((vault:db.password))
          run:
            path: flyway
            args: [migrate]
```

Concourse resolves `((vault:db.password))` as:
- var source name: `vault`
- key: `db.password` (dot notation maps to `db` secret, field `password`)
- full Vault path: `secret/data/concourse/payments/db` → field `password`

---

## How `path_prefix` Works

With `path_prefix: secret/data/concourse/payments`, Concourse constructs the Vault lookup path as:

```
<path_prefix>/<secret-name>
```

So `((vault:db.password))` resolves to:

```
GET secret/data/concourse/payments/db  →  .data.data.password
```

This matches your requirement exactly.

---

## Team Scoping — How Isolation Works

**The var_source is defined per-pipeline, not globally.** This means:

- Only the `payments` team's pipelines that include this `var_sources` block can resolve `((vault:...))` via this source.
- The `main` team's pipelines have no `vault` var source configured and cannot reach these secrets.
- No other team can "inherit" or access this var source.

**This is the correct isolation boundary in Concourse v8** — team-scoped var sources are pipeline-local. There is no global var source leakage between teams when configured this way.

Additionally, enforce the boundary at the Vault side with an AppRole policy:

```hcl
# vault policy: concourse-payments
path "secret/data/concourse/payments/*" {
  capabilities = ["read", "list"]
}
```

Bind this policy only to the AppRole used by the `payments` team. Even if another team somehow configured the same var source block, their AppRole credentials would lack the Vault policy to read these paths.

---

## The Chicken-and-Egg Problem: Bootstrapping the Var Source

The `var_sources` block itself needs credentials (`role_id` and `secret_id`) to authenticate to Vault. But where do those come from without hardcoding them?

### Answer: They come from the Concourse team's credential manager (the global one).

The reference `((vault-bootstrap:role_id))` uses a **different var source** named `vault-bootstrap`, or more commonly, the **default credential manager** configured at the Concourse ATC level (e.g., a separate Vault path, or even environment variables injected by the operator).

**Concourse's resolution order for values inside `var_sources.config`:**

1. Values in `config:` are resolved using the **pipeline's existing var sources** (already-resolved ones earlier in the list) **plus** the ATC-level global credential manager.
2. The ATC-level credential manager is configured by the Concourse operator via `--vault-*` flags or environment variables on the `web` component — it is not pipeline-visible.

### Practical bootstrap approaches:

**Option A: ATC-level global Vault (recommended)**

Configure the Concourse `web` component with its own Vault AppRole that has access to a bootstrap path:

```
# Concourse ATC environment (set by your platform/ops team)
CONCOURSE_VAULT_URL=https://vault.example.internal
CONCOURSE_VAULT_AUTH_BACKEND=approle
CONCOURSE_VAULT_AUTH_PARAM=role_id:$(cat /run/secrets/atc-role-id)
CONCOURSE_VAULT_AUTH_PARAM=secret_id:$(cat /run/secrets/atc-secret-id)
CONCOURSE_VAULT_PATH_PREFIX=/concourse
```

Then store the payments AppRole credentials in Vault at a path the ATC can read:

```
secret/concourse/payments/vault-bootstrap/role_id
secret/concourse/payments/vault-bootstrap/secret_id
```

Reference them in your pipeline as:

```yaml
auth_params:
  role_id: ((vault-bootstrap.role_id))    # resolved by ATC-level Vault
  secret_id: ((vault-bootstrap.secret_id))
```

**Option B: `fly set-pipeline` with `--var`**

Inject at pipeline set time — not stored in YAML, not visible in the UI:

```bash
fly -t payments set-pipeline \
  -p my-pipeline \
  -c pipeline.yml \
  --var "role_id=$VAULT_ROLE_ID" \
  --var "secret_id=$VAULT_SECRET_ID"
```

Then in the pipeline:

```yaml
auth_params:
  role_id: ((role_id))
  secret_id: ((secret_id))
```

These values are stored encrypted in the Concourse database, not in the YAML file. No static credentials in the pipeline YAML itself — requirement satisfied.

**Option C: Concourse Credhub or another secret backend for bootstrap creds**

If you use CredHub alongside Vault, store the AppRole creds there and reference via a CredHub var source (or the ATC-level CredHub integration).

---

## Summary

| Requirement | How It's Met |
|---|---|
| Team-scoped var source | `var_sources` block is per-pipeline; `payments` pipelines only |
| `((vault:db.password))` resolves `secret/data/concourse/payments/db` | `path_prefix: secret/data/concourse/payments` + key `db.password` |
| Vault CA cert | `ca_cert: /etc/ssl/certs/internal-ca.crt` |
| AppRole auth | `auth_backend: approle` with `role_id`/`secret_id` |
| No static creds in YAML | Credentials referenced via `((...))` vars, injected at `fly set-pipeline` or via ATC-level credential manager |
| Isolation from `main` team | `main` team pipelines don't have this var source; Vault policy restricts AppRole to `payments` paths |
