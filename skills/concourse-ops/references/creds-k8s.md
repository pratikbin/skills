# Kubernetes credential manager

Reads Kubernetes `Secret` objects as Concourse credentials. Useful when Concourse runs in-cluster.

## Config (web node)

```properties
# In-cluster (web node is a pod) — uses service account token
CONCOURSE_KUBERNETES_IN_CLUSTER=true

# OR: external kubeconfig
CONCOURSE_KUBERNETES_CONFIG_PATH=/etc/concourse/kube.yml

# Namespace prefix (default: concourse-)
# Team "main"   → namespace "concourse-main"
# Team "dev"    → namespace "concourse-dev"
CONCOURSE_KUBERNETES_NAMESPACE_PREFIX=concourse-
```

The web service account must have `get` and `list` on `secrets` in all team namespaces.

## RBAC example

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: concourse-secret-reader
  namespace: concourse-main
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: concourse-secret-reader
  namespace: concourse-main
subjects:
  - kind: ServiceAccount
    name: concourse-web
    namespace: concourse
roleRef:
  kind: Role
  name: concourse-secret-reader
  apiGroup: rbac.authorization.k8s.io
```

## Secret shape

Kubernetes `Secret` objects are type `Opaque`. Concourse looks up secrets by name, then reads a specific key.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials           # maps to ((db-credentials))
  namespace: concourse-main      # for team "main"
type: Opaque
stringData:
  username: admin
  password: hunter2
```

In pipeline YAML:
```yaml
# access a specific key
source:
  username: ((db-credentials.username))
  password: ((db-credentials.password))

# if the secret has a single key named "value", use plain lookup
api_key: ((api-key))
```

Concourse looks for a key named `value` first. If found, returns the string. If not, returns the entire secret as a map.

## Path lookup

Concourse looks in two namespaces:
1. `<prefix><team>-<pipeline>` — pipeline-specific (e.g. `concourse-main-deploy`)
2. `<prefix><team>` — team-wide (e.g. `concourse-main`)

If `CONCOURSE_KUBERNETES_NAMESPACE_PREFIX=concourse-`, team `main`, pipeline `deploy`:
- tries namespace `concourse-main-deploy` first
- falls back to `concourse-main`

## Pull-secret pattern

Grant Concourse's web service account the ability to read an image pull secret stored in a concourse namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: registry-pull-secret
  namespace: concourse-main
type: Opaque
stringData:
  value: '{"auths":{"registry.example.com":{"auth":"..."}}}'
```

Pipeline:
```yaml
image_resource:
  type: registry-image
  source:
    repository: registry.example.com/myapp
    password: ((registry-pull-secret))
```

## Gotchas

- Namespace naming is `<prefix><team>` and `<prefix><team>-<pipeline>`. There is no configurable template beyond the prefix.
- RBAC must be created per namespace. A ClusterRole bound per namespace is one approach; individual Role/RoleBinding per namespace is another.
- Kubernetes secrets are base64-encoded at rest but NOT encrypted unless etcd encryption is enabled. Enable etcd encryption for secrets at rest.
- `CONCOURSE_KUBERNETES_IN_CLUSTER=true` requires the web pod to have a service account token mounted.

## See also

- `references/vars-and-var-sources.md` — `var_sources:` for named Kubernetes sources
- `references/creds-caching-redacting.md` — cache + redact
