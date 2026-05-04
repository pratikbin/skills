# params-vs-vars.md

Two mechanisms for injecting values into tasks. Different interpolation timing, different security properties.

## Quick comparison

| | `params:` | `vars:` / `((name))` |
|---|---|---|
| Location | `task.yml` and task step | Anywhere in pipeline YAML |
| Resolved at | Task container start | Pipeline `set_pipeline` / build config load |
| Source | Literal values in YAML | Credential manager (Vault, CredHub, SSM, etc.) |
| Visible in `fly get-pipeline` | **Yes — plaintext** | No — substituted value not stored |
| Redacted in logs | No | Yes (credential manager redacts) |
| Fresh on each build | No (baked in YAML) | Yes (fetched each time) |
| Good for | Non-secret tunables | Actual secrets, dynamic values |

## `params:` — environment strings

`params:` in `task.yml` sets env vars when the container starts. Values come from:
1. The `params:` block inside `task.yml` (defaults).
2. The `params:` block on the task step in `pipeline.yml` (override).

```yaml
# task.yml
params:
  GO_VERSION: "1.22"    # default; can be overridden at step level
  PARALLELISM: "4"
  DEBUG: "false"
```

```yaml
# pipeline.yml task step — override a param
- task: build
  file: ci/tasks/build.yml
  params:
    GO_VERSION: "1.21"    # step-level params override task.yml defaults
    DEBUG: "true"
```

Inside the task script: `echo $GO_VERSION`, `echo $PARALLELISM`.

Good use: toolchain version, parallelism knob, feature flags, output verbosity. All non-secret, all visible in pipeline config.

## `vars:` / `((name))` — credential manager substitution

`((name))` placeholders are replaced at pipeline evaluation time by the configured credential manager. The resolved value is **never stored in the pipeline config**.

```yaml
# pipeline.yml — creds via vars
resources:
  - name: app-image
    type: registry-image
    source:
      repository: ghcr.io/org/app
      username: ((ghcr-user))      # fetched from Vault/CredHub/SSM at build time
      password: ((ghcr-pass))

jobs:
  - name: deploy
    plan:
      - task: run-deploy
        file: ci/tasks/deploy.yml
        vars:
          deploy_key: ((deploy-ssh-key))   # available as ((deploy_key)) inside task config
```

Secret values fetched from credential manager are redacted in logs (`***`). Not visible in `fly get-pipeline` output. Fetched fresh each build (subject to caching config).

## The plaintext leak gotcha

This is the number-one `params:` mistake:

```yaml
# WRONG — secret in params: is visible in fly get-pipeline
- task: push-image
  file: ci/tasks/push.yml
  params:
    REGISTRY_PASSWORD: my-secret-token   # plaintext in pipeline YAML
```

```yaml
# RIGHT — secret via vars/credential manager
- task: push-image
  file: ci/tasks/push.yml
  params:
    REGISTRY_PASSWORD: ((registry-password))  # resolved at runtime, not stored
```

`fly get-pipeline -p my-pipeline` will print `REGISTRY_PASSWORD: my-secret-token` verbatim in the first case. Any user with `fly get-pipeline` access sees it.

## When to use which

Use `params:` for:
- Go version, Node version, JDK version.
- Parallelism (`GOMAXPROCS`, test shard count).
- Feature flags (`ENABLE_EXPERIMENTAL: "true"`).
- Log levels, verbosity.
- Any value that's fine to see in `fly get-pipeline`.

Use `vars:` + credential manager for:
- Registry passwords, API tokens, SSH keys.
- Database URLs with embedded credentials.
- Anything that would be a secret in a `.env` file.

## Gotchas

- `params:` on the task step in the pipeline **overrides** defaults in `task.yml`. Intended behavior, but can cause surprise when debugging.
- `((name))` in `task.yml` itself is resolved at task load, not at step params evaluation. Keep `((…))` in pipeline YAML.
- `fly execute` does not connect to a credential manager. Use `--var` or `-l vars.yml` for local testing.
- Secret caching (`creds_cache_duration`) can mean a rotated secret is not picked up immediately.

## See also

- `schema.md` — params field in full task config
- `debugging.md` — `fly execute --var` for local secret injection
- `anti-patterns.md` — secrets in params
