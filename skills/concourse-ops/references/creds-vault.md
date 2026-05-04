# Vault credential manager

Full configuration reference for HashiCorp Vault as a Concourse credential backend.

## Server config (web node)

```properties
# Required
CONCOURSE_VAULT_URL=https://vault.example.com:8200

# TLS (if Vault uses a private CA)
CONCOURSE_VAULT_CA_CERT=/etc/concourse/vault-ca.pem
CONCOURSE_VAULT_CLIENT_CERT=/etc/concourse/vault-client.pem
CONCOURSE_VAULT_CLIENT_KEY=/etc/concourse/vault-client-key.pem

# Vault Enterprise namespace
CONCOURSE_VAULT_NAMESPACE=admin/concourse
```

## Auth backends

### Token (simplest, no renewal)

```properties
CONCOURSE_VAULT_CLIENT_TOKEN=s.my-vault-token
```

Token auth does not renew. Use only for testing or short-lived tokens.

### AppRole (recommended for production)

```properties
CONCOURSE_VAULT_AUTH_BACKEND=approle
CONCOURSE_VAULT_AUTH_PARAM=role_id:my-role-id
CONCOURSE_VAULT_AUTH_PARAM=secret_id:my-secret-id
```

Concourse renews the token automatically before expiry. The AppRole must have a policy granting `read` on the secrets path.

### Kubernetes (in-cluster web node)

```properties
CONCOURSE_VAULT_AUTH_BACKEND=kubernetes
CONCOURSE_VAULT_AUTH_PARAM=role:concourse-web
CONCOURSE_VAULT_AUTH_PARAM=jwt:@/var/run/secrets/kubernetes.io/serviceaccount/token
```

### Certificate (mTLS)

```properties
CONCOURSE_VAULT_AUTH_BACKEND=cert
CONCOURSE_VAULT_CLIENT_CERT=/etc/concourse/vault-client.pem
CONCOURSE_VAULT_CLIENT_KEY=/etc/concourse/vault-client-key.pem
```

## Path prefix and lookup templates

```properties
# default prefix is /concourse
CONCOURSE_VAULT_PATH_PREFIX=/concourse

# custom templates (comma-separated, tried in order)
CONCOURSE_VAULT_LOOKUP_TEMPLATES=/concourse/{{.Team}}/{{.Pipeline}}/{{.Secret}},/concourse/{{.Team}}/{{.Secret}},/concourse/shared/{{.Secret}}
```

Default templates (when not overridden):
1. `/concourse/<team>/<pipeline>/<secret>`
2. `/concourse/<team>/<secret>`

`{{.Team}}`, `{{.Pipeline}}`, `{{.Secret}}` are populated at lookup time.

## KV v1 vs KV v2

Concourse supports both. The difference is the path format:

```
# KV v1
secret/concourse/main/my-pipeline/db-password

# KV v2 (adds /data/ in path)
secret/data/concourse/main/my-pipeline/db-password
```

For KV v2 you must set the path prefix to include `/data/` or adjust lookup_templates accordingly. Concourse does NOT auto-detect KV version.

## Lease renewal

Concourse's web node renews Vault tokens (AppRole, cert, kubernetes auth) automatically. Set `CONCOURSE_VAULT_AUTH_RETRY_MAX` (default `5m`) to control backoff on renewal failures.

For secrets themselves: leased dynamic secrets (e.g. database creds) are renewed until the max TTL. If the lease expires mid-build, Concourse does not re-fetch mid-step (caching applies). Set `CONCOURSE_SECRET_CACHE_DURATION` to control how long fetched values are kept.

## Example: AppRole with custom path

```properties
CONCOURSE_VAULT_URL=https://vault.corp.example.com
CONCOURSE_VAULT_CA_CERT=/run/secrets/vault-ca
CONCOURSE_VAULT_AUTH_BACKEND=approle
CONCOURSE_VAULT_AUTH_PARAM=role_id:abc123
CONCOURSE_VAULT_AUTH_PARAM=secret_id:def456
CONCOURSE_VAULT_PATH_PREFIX=/secrets
CONCOURSE_VAULT_LOOKUP_TEMPLATES=/secrets/{{.Team}}/{{.Pipeline}}/{{.Secret}},/secrets/{{.Team}}/{{.Secret}}
```

Pipeline YAML:
```yaml
resources:
  - name: app-db
    type: postgres
    source:
      password: ((db-password))   # resolves /secrets/my-team/my-pipeline/db-password
```

## Gotchas

- Token auth has no renewal. Use AppRole or kubernetes in production.
- KV v2 paths include `/data/` — misconfigure this and all secret lookups 404.
- Vault namespaces (Enterprise) require the `CONCOURSE_VAULT_NAMESPACE` env var; the namespace is NOT part of the URL path.
- If Vault is down, builds fail at secret-fetch time. Enable `CONCOURSE_SECRET_CACHE_ENABLED=true` to buffer short outages.

## See also

- `references/vars-and-var-sources.md` — interpolation, path_prefix, lookup_templates
- `references/creds-caching-redacting.md` — secret cache + retry policy
