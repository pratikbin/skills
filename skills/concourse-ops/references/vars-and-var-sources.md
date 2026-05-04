# Vars and var sources

How Concourse resolves `((var))` references: interpolation syntax, scopes, and configuring `var_sources`.

## Interpolation syntax

```
((var))                   # simple lookup
((source:var))            # lookup in named var_source
((source:path/to/var))    # nested path within a source
((source:path/to.field))  # field on a map secret
```

Concourse interpolates at step execution time, not pipeline set time. Unresolved vars cause a build error.

Local build vars (set by `load_var` or `across`) use `((.:var))` (dot prefix).

## Lookup order

1. Local build vars (`((.:var))`)
2. Named `var_source` (`((source:var))`)
3. Pipeline-level `var_sources:` (unnamed, in declaration order)
4. Team-level var sources (set via `fly set-team`)
5. Cluster-level credential manager (web node env)

First match wins. If nothing resolves, the build errors.

## load_var step

```yaml
plan:
  - get: repo
  - load_var: git-ref
    file: repo/.git/ref          # read file contents into var
  - task: build
    config:
      params:
        GIT_REF: ((.:git-ref))   # dot prefix = local var
```

`load_var` supports `format: raw` (default), `yaml`, or `json`. JSON/YAML files are parsed as maps; fields accessible via `((.:var.field))`.

## Pipeline-level var_sources

```yaml
var_sources:
  - name: vault
    type: vault
    config:
      url: https://vault.example.com
      auth_backend: approle
      auth_params:
        role_id: ((vault_role_id))
        secret_id: ((vault_secret_id))

  - name: k8s-secrets
    type: kubernetes
    config:
      in_cluster: true
      namespace_prefix: concourse-
```

Named sources are referenced as `((vault:my-secret))`. Unnamed cluster source is the fallback.

## Cluster-level default source

Set via web node environment. Only one credential manager can be the cluster default. All `((var))` without a named source prefix fall through to this.

```properties
# Vault as cluster default (no prefix needed in pipeline YAML)
CONCOURSE_VAULT_URL=https://vault.example.com
CONCOURSE_VAULT_AUTH_BACKEND=approle
CONCOURSE_VAULT_AUTH_PARAM=role_id:my-role-id
CONCOURSE_VAULT_AUTH_PARAM=secret_id:my-secret-id
```

## path_prefix

Controls the Vault / SSM / CredHub path prefix. Default is `/concourse`.

```properties
CONCOURSE_VAULT_PATH_PREFIX=/secrets
```

With prefix `/secrets` and team `main`, pipeline `ci`, secret `db-pass`:
- tried: `/secrets/main/ci/db-pass`
- tried: `/secrets/main/db-pass`

## lookup_templates

Override the exact paths Vault searches. Supports Go template vars `{{.Team}}`, `{{.Pipeline}}`, `{{.Secret}}`.

```properties
CONCOURSE_VAULT_LOOKUP_TEMPLATES=/{{.Team}}/concourse/{{.Pipeline}}/{{.Secret}},/{{.Team}}/concourse/{{.Secret}},/common/{{.Secret}}
```

Templates are tried in order; first hit wins. Adding `/common/{{.Secret}}` allows shared cross-team secrets.

## retry_config (retrying-failed)

```yaml
var_sources:
  - name: vault
    type: vault
    config:
      url: https://vault.example.com
      auth_backend: approle
      auth_params:
        role_id: myrole
        secret_id: mysecret
      retry_config:
        attempts: 5
        interval: 2s
```

Also available as cluster default via `CONCOURSE_SECRET_RETRY_ATTEMPTS` and `CONCOURSE_SECRET_RETRY_INTERVAL`.

## Gotchas

- `((var))` in `set_pipeline` flags (like `-v key=((other))`) is NOT interpolated at `fly` call time. Only at build execution time.
- `fly validate-pipeline --output` shows the interpolated YAML without uploading. Useful for debugging.
- A var_source name must be unique within a pipeline's `var_sources` list.
- `load_var` requires a `get` step output dir to read from. Cannot read arbitrary filesystem paths.

## See also

- `references/creds-vault.md` — Vault var_source config
- `references/creds-aws.md` — AWS Secrets Manager / SSM
- `references/creds-k8s.md` — Kubernetes secrets
- `references/creds-id-token.md` — IDToken/OIDC federation
- `references/creds-caching-redacting.md` — cache + redact secrets
