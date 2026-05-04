# Credential caching and secret redaction

Operators control how long fetched secrets are cached and whether secret values are scrubbed from build logs.

## Secret caching

Without caching, Concourse fetches secrets from the backend (Vault, SSM, etc.) on every step that needs them. For high-build-frequency clusters this hammers the secret backend.

### Config (web node)

```properties
# Enable caching (default: false)
CONCOURSE_SECRET_CACHE_ENABLED=true

# How long to cache a fetched secret (default: 1m)
CONCOURSE_SECRET_CACHE_DURATION=5m

# How long to cache a "secret not found" response (default: 10s)
CONCOURSE_SECRET_CACHE_DURATION_NOTFOUND=30s

# Purge cached secrets when a pipeline is paused/unpaused (default: true)
CONCOURSE_SECRET_CACHE_PURGE_INTERVAL_DISABLED=false
```

### What caching covers

- Positive lookups: the resolved secret value is cached per `(team, pipeline, secret-name)` tuple.
- Negative lookups: "not found" results are also cached to avoid hammering backends when a secret doesn't exist.

### Cache invalidation

Cached entries expire after `CONCOURSE_SECRET_CACHE_DURATION`. There is no manual flush command. To force a re-fetch, pause then unpause the pipeline (clears the pipeline's cache entries).

## Secret redaction

Concourse v8+ enables redaction by default. Redaction scrubs known secret values from build log output.

### Config (web node)

```properties
# Enabled by default in v8+. Explicit opt-in for older:
CONCOURSE_ENABLE_REDACT_SECRETS=true
```

### How redaction works

When a secret is fetched, its value is registered in the redaction filter. Any build log line containing that exact string has it replaced with `((redacted))`.

### What redaction does NOT catch

- Values fetched by a task and stored in environment variables or files — if the task later echoes them, the redaction filter covers the echo output.
- Secrets constructed dynamically inside a container (e.g. concatenating two partial secrets) — redaction only knows the original fetched string.
- Multi-line or structured secrets: only the exact fetched string is matched. JSON values are matched as a whole blob, not field-by-field.
- Secrets passed via `params:` that come from pipeline YAML directly (not a `((var))` lookup) are NOT redacted.

## Retry policy (retrying-failed)

When the credential backend is temporarily unavailable, configure Concourse to retry:

```properties
# Number of retry attempts on lookup failure
CONCOURSE_SECRET_RETRY_ATTEMPTS=5

# Interval between attempts
CONCOURSE_SECRET_RETRY_INTERVAL=2s
```

Per-source retry in `var_sources:`:

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

Source-level `retry_config` overrides cluster defaults for that specific source.

## Examples

### Production caching setup

```properties
CONCOURSE_SECRET_CACHE_ENABLED=true
CONCOURSE_SECRET_CACHE_DURATION=5m
CONCOURSE_SECRET_CACHE_DURATION_NOTFOUND=1m
CONCOURSE_ENABLE_REDACT_SECRETS=true
CONCOURSE_SECRET_RETRY_ATTEMPTS=3
CONCOURSE_SECRET_RETRY_INTERVAL=5s
```

### Debug: disable cache temporarily

```properties
CONCOURSE_SECRET_CACHE_ENABLED=false
```

Restart the web node. All subsequent secret fetches go directly to the backend. Re-enable after debugging.

## Gotchas

- Caching happens on the web node; worker nodes don't cache secrets independently.
- Very long cache durations (`>10m`) mean builds run after a secret rotation may use stale values until expiry.
- Redaction is best-effort. Don't rely on it as the sole protection against secrets leaking in logs.
- `CONCOURSE_SECRET_CACHE_DURATION=0` disables caching effectively. Prefer `CONCOURSE_SECRET_CACHE_ENABLED=false` for clarity.

## See also

- `references/creds-vault.md` — Vault backend details
- `references/vars-and-var-sources.md` — retry_config per var_source
