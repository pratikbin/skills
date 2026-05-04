# AWS credential managers (Secrets Manager + SSM)

Two separate backends. Can be enabled simultaneously. Each uses independent env vars.

## AWS Secrets Manager

### Config (web node)

```properties
# Region (required)
CONCOURSE_AWS_SECRETSMANAGER_REGION=us-east-1

# IAM — option 1: env vars (dev/CI)
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# IAM — option 2: assume-role (web node role → target role)
CONCOURSE_AWS_SECRETSMANAGER_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE
CONCOURSE_AWS_SECRETSMANAGER_SECRET_KEY=wJalrXUtnFEMI...
CONCOURSE_AWS_SECRETSMANAGER_SESSION_TOKEN=token-if-sts

# IAM — option 3: instance profile / EKS IRSA (no env vars needed)
# Just set the region; AWS SDK picks up the instance metadata credentials.
```

### Path templates

Default lookup order for `((my-secret))` in team `main`, pipeline `deploy`:
1. `/concourse/main/deploy/my-secret`
2. `/concourse/main/my-secret`

Override with:
```properties
CONCOURSE_AWS_SECRETSMANAGER_PIPELINE_SECRET_TEMPLATE=/concourse/{{.Team}}/{{.Pipeline}}/{{.Secret}}
CONCOURSE_AWS_SECRETSMANAGER_TEAM_SECRET_TEMPLATE=/concourse/{{.Team}}/{{.Secret}}
```

### Secret shape

Secrets Manager stores a secret as a string or JSON blob. Concourse handles both:

```json
// JSON blob — field access via ((my-secret.username))
{ "username": "admin", "password": "hunter2" }
```

```
// Plain string — use ((my-secret)) directly
hunter2
```

A plain string secret is returned as-is. A JSON secret allows `((secret.field))` dot notation.

## AWS SSM Parameter Store

### Config (web node)

```properties
CONCOURSE_AWS_SSM_REGION=us-east-1

# IAM — same options as Secrets Manager above
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI...

# path prefix (default /concourse)
CONCOURSE_AWS_SSM_PATH_PREFIX=/concourse
```

### Path templates

```properties
CONCOURSE_AWS_SSM_PIPELINE_SECRET_TEMPLATE=/concourse/{{.Team}}/{{.Pipeline}}/{{.Secret}}
CONCOURSE_AWS_SSM_TEAM_SECRET_TEMPLATE=/concourse/{{.Team}}/{{.Secret}}
```

Parameter names map directly. Use `SecureString` type for sensitive values; Concourse requests decryption automatically.

## Examples

### Enabling both backends

```properties
# Secrets Manager
CONCOURSE_AWS_SECRETSMANAGER_REGION=us-east-1

# SSM
CONCOURSE_AWS_SSM_REGION=us-east-1
CONCOURSE_AWS_SSM_PATH_PREFIX=/concourse
```

Concourse checks Secrets Manager first, then SSM for the same `((var))`. First hit wins.

### Instance profile / IRSA (no static keys)

For an EKS-hosted Concourse web deployment with IRSA:

```properties
CONCOURSE_AWS_SECRETSMANAGER_REGION=us-east-1
# No key env vars — AWS SDK uses IRSA token
```

Attach the IAM role policy:
```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue"],
  "Resource": "arn:aws:secretsmanager:us-east-1:123456789012:secret:concourse/*"
}
```

## Gotchas

- Secrets Manager and SSM use separate env var prefixes; don't mix them.
- SSM `StringList` type is not supported; use `String` or `SecureString`.
- Secrets Manager JSON field access uses `.` notation: `((secret.password))`. Nested JSON is not supported beyond one level.
- If you use assume-role, the ATC process needs IAM credentials to perform the `sts:AssumeRole` call. Instance profile or IRSA is cleaner.
- Regional endpoints: Secrets Manager calls go to the specified region; make sure the secrets exist there.

## See also

- `references/vars-and-var-sources.md` — interpolation, lookup order
- `references/creds-id-token.md` — OIDC federation to AWS without static keys
- `references/creds-caching-redacting.md` — cache + redact
