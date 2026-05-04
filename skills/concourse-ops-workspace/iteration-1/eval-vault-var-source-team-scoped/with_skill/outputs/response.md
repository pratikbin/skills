# Team-Scoped Vault Var Source for the `payments` Team

## The `var_sources` block for your `pipeline.yml`

```yaml
var_sources:
  - name: vault
    type: vault
    config:
      url: https://vault.example.internal
      ca_cert: /etc/ssl/certs/internal-ca.crt
      auth_backend: approle
      auth_params:
        role_id: ((vault:payments-bootstrap.role_id))
        secret_id: ((vault:payments-bootstrap.secret_id))
      path_prefix: /secret/data/concourse/payments
```

With this config, `((vault:db.password))` in a pipeline step resolves to:

```
secret/data/concourse/payments/db  →  field: password
```

Concourse reads the `db` secret from that KV v2 path and extracts the `password` field.

---

## Usage in pipeline resources / tasks

```yaml
resources:
  - name: payments-db
    type: some-db-resource
    source:
      password: ((vault:db.password))
```

The `vault:` prefix tells Concourse to use the named `vault` var_source defined above, rather than the cluster-level default.

---

## Team isolation — why this is scoped to `payments` only

The var_source lives inside the `payments` team's pipeline YAML. It is **not** visible to `main` or any other team because:

1. `var_sources` declared in a pipeline are scoped to that pipeline, which is owned by the team that set it.
2. The AppRole credentials (`role_id` / `secret_id`) are resolved at runtime inside the `payments` team's build — other teams' builds never see those values.
3. The Vault policy attached to the AppRole should **only** grant `read` capability on `secret/data/concourse/payments/*`. Other teams' AppRoles (or the cluster-level credential manager) will not have that policy, so even if they tried the same path they would get a 403.

Your Vault policy for the `payments` AppRole should look like:

```hcl
path "secret/data/concourse/payments/*" {
  capabilities = ["read"]
}

# Allow token renewal
path "auth/token/renew-self" {
  capabilities = ["update"]
}
```

---

## The chicken-and-egg: where do `role_id` / `secret_id` come from?

This is the central bootstrapping question. The var_source itself needs credentials to talk to Vault — those credentials can't come from the same Vault source being configured. Here are the supported options:

### Option 1: From the cluster-level credential manager (recommended)

If your Concourse web node already has a cluster-level Vault configured (via `CONCOURSE_VAULT_*` env vars pointing at the same or a different Vault), you can store the AppRole credentials there:

```
secret/data/concourse/payments/payments-bootstrap  →  { role_id: "...", secret_id: "..." }
```

Then in the pipeline:

```yaml
auth_params:
  role_id: ((payments-bootstrap.role_id))         # resolves via cluster-level Vault
  secret_id: ((payments-bootstrap.secret_id))
```

No `vault:` prefix here — these fall through to the cluster default, which the `payments` team operator has seeded once. The team-scoped `vault` var_source then uses those credentials for all subsequent secret lookups.

### Option 2: From environment variables via `fly set-pipeline -v`

Pass the credentials at pipeline-set time (not stored in the YAML):

```bash
fly -t prod set-pipeline \
  -p payments-pipeline \
  -c pipeline.yml \
  -v vault_role_id="$VAULT_ROLE_ID" \
  -v vault_secret_id="$VAULT_SECRET_ID"
```

And in the pipeline:

```yaml
auth_params:
  role_id: ((vault_role_id))
  secret_id: ((vault_secret_id))
```

These values are stored encrypted in Concourse's database and injected at runtime. No static credentials in the YAML file itself — `$VAULT_ROLE_ID` and `$VAULT_SECRET_ID` live in your deploy environment, not the repo.

### Option 3: From a team-level var source (Concourse v8)

In Concourse v8 you can configure a var source at the **team level** using `fly set-team --var-source`. This is seeded once by a team admin and is available to all pipelines in that team without being declared in each pipeline:

```bash
fly -t prod set-team \
  --team-name payments \
  --var-source name=vault,type=vault,url=https://vault.example.internal,...
```

Pipelines in the `payments` team can then reference `((vault:...))` without declaring the `var_sources` block in every pipeline YAML. The bootstrap credentials are held at the team level, visible only to team owners.

---

## KV v2 path note

Your Vault path is `secret/data/concourse/payments/db`. Setting `path_prefix: /secret/data/concourse/payments` means Concourse will look up:

```
/secret/data/concourse/payments/db  →  field: password
```

for `((vault:db.password))`. This is correct for KV v2 (the `/data/` segment is required). Concourse does **not** auto-detect KV version — if you omit `/data/` in the prefix, lookups will silently 404.

---

## Summary

| Concern | Answer |
|---|---|
| Var source scope | Declared in `payments` pipeline — not shared |
| Other teams can read these secrets? | No — Vault policy restricts the AppRole to `payments/*` paths only |
| Static creds in YAML? | No — bootstrapped via cluster Vault, `fly -v`, or team-level var source |
| KV v2 path format | Include `/data/` in `path_prefix` |
| `role_id`/`secret_id` source at boot | Cluster-level Vault (recommended), or `-v` at `fly set-pipeline` time |
