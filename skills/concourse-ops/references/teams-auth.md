# Teams and authentication

How to create teams, configure auth providers, and assign roles.

## Roles

Concourse has five roles, strictly ordered (higher includes all lower permissions):

| Role | Scope |
|------|-------|
| Concourse Admin | Cluster-wide. Manage all teams. Only `main` team members. |
| Owner | Full control of the team: set pipelines, set-team, destroy team. |
| Member | Set pipelines, trigger jobs, get secrets. |
| Pipeline Operator | Trigger/pause jobs, abort builds. Cannot set pipelines. |
| Viewer | Read-only: see pipelines, builds, logs. |

## fly set-team

```bash
# create or update a team
fly -t admin set-team -n my-team \
    --github-user alice \
    --github-org my-org \
    --github-team my-org:infra-team

# OIDC
fly -t admin set-team -n my-team \
    --oidc-user alice@example.com \
    --oidc-group engineering

# local users (no external auth)
fly -t admin set-team -n dev-team \
    --local-user dev-alice \
    --local-user dev-bob

# assign a role (default is owner for all flags; member/viewer/pipeline-operator require --role)
fly -t admin set-team -n my-team \
    --github-team my-org:dev-team \
    --role member
```

Without `--role`, users/groups are assigned `owner`. Use `--role member`, `--role viewer`, or `--role pipeline-operator` to grant narrower permissions.

## Auth providers

### GitHub

```bash
fly -t admin set-team -n my-team \
    --github-user alice \                  # individual user
    --github-org my-org \                  # any member of org
    --github-team my-org:infra             # specific team in org
```

Requires `CONCOURSE_GITHUB_CLIENT_ID` and `CONCOURSE_GITHUB_CLIENT_SECRET` on the web node.

### OIDC (generic; works with Google, Okta, Dex, etc.)

```bash
fly -t admin set-team -n my-team \
    --oidc-user alice@example.com \
    --oidc-group engineering
```

```properties
# web node config
CONCOURSE_OIDC_DISPLAY_NAME=Okta
CONCOURSE_OIDC_ISSUER=https://okta.example.com
CONCOURSE_OIDC_CLIENT_ID=my-client-id
CONCOURSE_OIDC_CLIENT_SECRET=my-client-secret
CONCOURSE_OIDC_SCOPE=openid,profile,email,groups
CONCOURSE_OIDC_GROUPS_KEY=groups
```

### SAML

```properties
CONCOURSE_SAML_DISPLAY_NAME=Corp SSO
CONCOURSE_SAML_SSO_URL=https://sso.example.com/sso/saml
CONCOURSE_SAML_SSO_ISSUER=https://sso.example.com/saml
CONCOURSE_SAML_CA_CERT=/etc/concourse/saml-ca.pem
```

### LDAP

```properties
CONCOURSE_LDAP_DISPLAY_NAME=LDAP
CONCOURSE_LDAP_HOST=ldap.example.com:389
CONCOURSE_LDAP_BIND_DN=cn=concourse,dc=example,dc=com
CONCOURSE_LDAP_BIND_PASSWORD=ldap-pass
CONCOURSE_LDAP_USER_SEARCH_BASE_DN=ou=users,dc=example,dc=com
CONCOURSE_LDAP_GROUP_SEARCH_BASE_DN=ou=groups,dc=example,dc=com
```

### Local users (no external provider)

```properties
# web node
CONCOURSE_ADD_LOCAL_USER=alice:password1,bob:password2
```

```bash
fly -t admin set-team -n dev-team --local-user alice
```

### Other providers

Concourse also supports: BitBucket, GitLab, Microsoft (Azure AD), Cloud Foundry UAA, generic-oauth2. Each has its own `CONCOURSE_<PROVIDER>_*` env vars. All follow the same `fly set-team --<provider>-user / --<provider>-group` flag pattern.

## main team specialness

- The `main` team is the only team that has Concourse Admin role.
- `main` team config is set via web node env (`CONCOURSE_MAIN_TEAM_*` flags), not `fly set-team`.
- Cannot be deleted. Cannot lose all admin users (locked-out protection).

```properties
# lock main team to github org + local admin
CONCOURSE_MAIN_TEAM_GITHUB_ORG=my-org
CONCOURSE_MAIN_TEAM_LOCAL_USER=admin
```

## Multi-tenancy caveats

- Teams are isolated: pipelines, builds, secrets are per-team.
- Workers are shared across teams unless tagged with `--tag` and resources/tasks use matching `tags:`.
- A Concourse Admin (main team owner) can see all teams' pipelines and builds via the API.
- Secrets configured via cluster-level credential manager are looked up in the team's namespace — teams cannot read each other's secrets by design.
- `fly set-team` with no auth flags creates a team open to every authenticated user — avoid this.

## Gotchas

- Without `--role`, all auth flags assign the `owner` role. Be explicit.
- Removing all auth from a team locks everyone out. The main team admin can then destroy/recreate it.
- `CONCOURSE_GITHUB_CLIENT_ID` must be set before `fly set-team --github-*` flags take effect.
- Local users are cluster-wide; you still need `fly set-team --local-user` to grant them access to a specific team.

## See also

- `references/fly-cli.md` — `fly set-team`, `fly userinfo`, `fly active-users`
- `references/perf-tuning.md` — worker tagging for team isolation
