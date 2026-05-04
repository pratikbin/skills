# IDToken / OIDC credential source

Mint short-lived JWTs per build for keyless credential federation to cloud providers.

## What it is

Concourse's `idtoken` var_source generates a JWT for each build. The JWT is signed by a Concourse-managed key pair and contains build metadata as claims. Cloud providers (AWS, GCP, Azure, etc.) can be configured to trust this issuer via OIDC federation — exchanging the JWT for short-lived cloud credentials without static API keys stored anywhere.

Signing keys are auto-rotated every 7 days. Previous keys are retained 24h so in-flight builds keep working.

## Prerequisites (operator)

The Concourse external URL must be publicly reachable for OIDC discovery. Cloud providers hit `<CONCOURSE_EXTERNAL_URL>/.well-known/openid-configuration` to fetch the JWK set.

Optional: set a dedicated OIDC issuer URL (separate from external URL):
```properties
CONCOURSE_OIDC_ISSUER_URL=https://concourse-oidc.example.com
```

## Pipeline var_sources schema

```yaml
var_sources:
  - name: awstoken
    type: idtoken
    config:
      audience:
        - sts.amazonaws.com          # AWS STS expects this audience

  - name: gcptoken
    type: idtoken
    config:
      audience:
        - https://iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/my-pool/providers/concourse

  - name: azuretoken
    type: idtoken
    config:
      audience:
        - api://AzureADTokenExchange
```

Lookup format: `((source-name:role-or-identifier))` — the lookup key is passed as the audience hint; Concourse returns a JWT token string.

## JWT claims

| Claim | Value |
|-------|-------|
| `iss` | Concourse external URL (or OIDC issuer URL) |
| `aud` | Configured audience list |
| `sub` | `team:<team>:pipeline:<pipeline>` |
| `concourse_build_id` | Build ID |
| `concourse_build_name` | Build number |
| `concourse_team_name` | Team name |
| `concourse_pipeline_name` | Pipeline name |

## Examples

### AWS assume-role-with-web-identity

```yaml
var_sources:
  - name: awstoken
    type: idtoken
    config:
      audience: ["sts.amazonaws.com"]

jobs:
  - name: deploy
    plan:
      - task: aws-deploy
        config:
          platform: linux
          image_resource:
            type: registry-image
            source: { repository: amazon/aws-cli, tag: latest }
          params:
            AWS_TOKEN: ((awstoken:token))
            ROLE_ARN: arn:aws:iam::123456789012:role/my-deploy-role
          run:
            path: bash
            args:
              - -ec
              - |
                aws sts assume-role-with-web-identity \
                  --role-session-name concourse-build \
                  --role-arn "$ROLE_ARN" \
                  --web-identity-token "$AWS_TOKEN" \
                  > /tmp/creds.json
                export AWS_ACCESS_KEY_ID=$(jq -r .Credentials.AccessKeyId /tmp/creds.json)
                export AWS_SECRET_ACCESS_KEY=$(jq -r .Credentials.SecretAccessKey /tmp/creds.json)
                export AWS_SESSION_TOKEN=$(jq -r .Credentials.SessionToken /tmp/creds.json)
                aws s3 ls s3://my-bucket
```

### GCP workload identity federation

```yaml
var_sources:
  - name: gcptoken
    type: idtoken
    config:
      audience:
        - "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/ci-pool/providers/concourse"
```

Configure GCP WIF pool to trust `iss` = Concourse URL and subject condition matching `team:main:pipeline:*`.

### Azure federated credentials

```yaml
var_sources:
  - name: azuretoken
    type: idtoken
    config:
      audience: ["api://AzureADTokenExchange"]
```

Configure Azure AD federated credential with issuer = Concourse URL and subject = `team:main:pipeline:deploy`.

## Advantages over static credentials

- No long-lived secrets stored in Vault / SSM.
- Credentials expire after each build; stolen tokens have a very short TTL.
- Cloud provider audit logs show the Concourse build as identity.
- Key rotation is automatic.

## Caveats

- Concourse external URL must be publicly accessible to cloud provider's OIDC validation endpoint.
- One-off `fly execute` builds produce a JWT with `pipeline: ""`. Cloud IAM subject conditions on pipeline name won't match.
- JWT TTL is tied to build duration. Very long builds (>1h) may require cloud-side session duration to be extended.

## See also

- `references/vars-and-var-sources.md` — var_sources configuration
- `references/creds-aws.md` — AWS with IRSA / static keys alternative
