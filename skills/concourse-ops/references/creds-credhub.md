# CredHub credential manager

Integrates with Cloud Foundry CredHub for credential storage. Uses mTLS or UAA client credentials.

## Config (web node)

```properties
# Required
CONCOURSE_CREDHUB_URL=https://credhub.example.com:8844

# Auth option 1: UAA client credentials
CONCOURSE_CREDHUB_CLIENT_ID=concourse
CONCOURSE_CREDHUB_CLIENT_SECRET=my-uaa-client-secret

# Auth option 2: mTLS client certificate
CONCOURSE_CREDHUB_CLIENT_CERT=/etc/concourse/credhub-client.pem
CONCOURSE_CREDHUB_CLIENT_KEY=/etc/concourse/credhub-client-key.pem

# CA for CredHub server TLS verification
CONCOURSE_CREDHUB_CA_CERT=/etc/concourse/credhub-ca.pem

# Path prefix (default /concourse)
CONCOURSE_CREDHUB_PATH_PREFIX=/concourse
```

## Path lookup

With `path_prefix=/concourse`, team `main`, pipeline `deploy`, secret `db-pass`:

1. `/concourse/main/deploy/db-pass`
2. `/concourse/main/db-pass`

Override with:
```properties
CONCOURSE_CREDHUB_PATH_PREFIX=/custom-prefix
```

## Examples

### UAA auth

```properties
CONCOURSE_CREDHUB_URL=https://credhub.internal:8844
CONCOURSE_CREDHUB_CA_CERT=/run/secrets/credhub-ca.pem
CONCOURSE_CREDHUB_CLIENT_ID=concourse-client
CONCOURSE_CREDHUB_CLIENT_SECRET=s3cr3t
CONCOURSE_CREDHUB_PATH_PREFIX=/concourse
```

### mTLS auth (CF BOSH deployment typical)

```properties
CONCOURSE_CREDHUB_URL=https://credhub.service.cf.internal:8844
CONCOURSE_CREDHUB_CA_CERT=/var/vcap/jobs/atc/config/credhub-ca.pem
CONCOURSE_CREDHUB_CLIENT_CERT=/var/vcap/jobs/atc/config/credhub-client.pem
CONCOURSE_CREDHUB_CLIENT_KEY=/var/vcap/jobs/atc/config/credhub-client.key
```

### Storing a credential in CredHub

```bash
# Using credhub CLI
credhub set -n /concourse/main/deploy/db-password \
    -t password -w hunter2

# JSON credential (map access via ((db-creds.username)))
credhub set -n /concourse/main/db-creds \
    -t json -v '{"username":"admin","password":"hunter2"}'
```

In pipeline YAML:
```yaml
source:
  password: ((db-password))
  username: ((db-creds.username))
```

## CredHub credential types

| Type | Access |
|------|--------|
| `password` | `((name))` → string |
| `value` | `((name))` → string |
| `json` | `((name.field))` → field value |
| `user` | `((name.username))`, `((name.password))` |
| `certificate` | `((name.ca))`, `((name.certificate))`, `((name.private_key))` |
| `rsa` | `((name.public_key))`, `((name.private_key))` |
| `ssh` | `((name.public_key))`, `((name.private_key))` |

## Gotchas

- CredHub requires TLS. `CONCOURSE_CREDHUB_CA_CERT` is required if the cert is not in the system CA pool.
- UAA and mTLS auth are mutually exclusive. Pick one.
- Path prefix must match where secrets are stored. Mismatched prefix = 404 on every lookup.
- CredHub credential type `certificate` exposes sub-fields. Accessing `((name))` directly returns the entire certificate object, not just the PEM.

## See also

- `references/vars-and-var-sources.md` — interpolation, path lookup
- `references/creds-caching-redacting.md` — cache + redact
