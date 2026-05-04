# registry-image.md — `registry-image` resource type schema and patterns

Check, fetch, and push OCI-compatible container images to/from any Docker-compatible registry.

---

## Schema

```yaml
resources:
  - name: app-image
    type: registry-image
    source:
      repository: ghcr.io/example/app   # required; registry/org/image (no tag)
      tag: "1.4.2"                       # optional; default "latest"; mutable tag or fixed semver
      username: ((registry.username))    # optional; registry login
      password: ((registry.password))    # optional; registry login or token

      # semver-tracking (alternative to pinning a tag)
      semver_constraint: ">=1.4 <2"     # optional; only match tags satisfying this constraint
      pre_releases: false               # optional; include alpha/beta/rc pre-releases in semver check

      # tag pattern matching (alternative to tag + semver)
      tag_regex: "^v[0-9]+\\.[0-9]+"   # optional; check only tags matching this regex
      created_at_sort: false            # optional; sort tag_regex results by creation time (newest first)

      # variant / multi-arch
      variant: alpine                   # optional; semver variant suffix (e.g. "alpine", "slim")
      platform:                         # optional; select a specific manifest list entry
        os: linux
        architecture: arm64

      # AWS ECR
      aws_access_key_id: ((aws.key-id))
      aws_secret_access_key: ((aws.secret))
      aws_session_token: ((aws.session))     # optional; for assumed roles
      aws_region: us-east-1                  # optional; defaults to us-east-1
      aws_role_arn: arn:aws:iam::123:role/ci # optional; assume this role for ECR token

      # content trust (DCT/Notary)
      content_trust:
        server: https://notary.docker.io
        repository_key_id: ((dct.key-id))
        repository_key: ((dct.key))
        repository_passphrase: ((dct.passphrase))
        username: ((dct.username))
        password: ((dct.password))
```

### `get` params

```yaml
- get: app-image
  params:
    format: oci          # optional; rootfs (default) | oci — how to unpack the image
    skip_download: false # optional; skip actually downloading the image layers
```

### `put` params

```yaml
- put: app-image
  params:
    image: build/image.tar          # required; path to OCI tar from oci-build-task or similar
    version: 1.5.0                  # optional; version tag to push (in addition to source.tag)
    bump_aliases: false             # optional; also push major and minor alias tags (1.5.0 → 1, 1.5)
    tag_as_latest: false            # optional; also push as "latest"
    additional_tags: tags.txt       # optional; file containing newline-separated extra tags
  get_params:
    skip_download: true             # optional; avoid pulling the image back after push
```

---

## Examples

### Pin by digest — most reproducible

```yaml
resources:
  - name: golang-image
    type: registry-image
    check_every: never              # won't change unless you update the config
    source:
      repository: golang
      tag: "1.22.3"
      # To pin by digest instead of tag, set the pipeline-level version:
      # version:
      #   digest: sha256:abc123...
```

Pinning by digest ensures byte-identical image. Update by changing the digest or tag in pipeline config.

---

### Semver-tracked image — follow minor releases safely

```yaml
resources:
  - name: base-image
    type: registry-image
    check_every: 4h
    source:
      repository: ghcr.io/example/base
      semver_constraint: ">=2.0 <3"
      username: ((ghcr.username))
      password: ((ghcr.token))
```

`check` will emit new versions whenever a tag satisfying `>=2.0 <3` is pushed. Protects against accidental major bumps.

---

### Multi-arch fetch for ARM builder

```yaml
resources:
  - name: ubuntu-arm64
    type: registry-image
    source:
      repository: ubuntu
      tag: "24.04"
      platform:
        os: linux
        architecture: arm64
```

Without `platform`, Concourse picks the host platform's arch from a manifest list. Set explicitly when building cross-arch.

---

### Private registry with ECR

```yaml
resources:
  - name: ecr-app
    type: registry-image
    source:
      repository: 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp
      aws_access_key_id: ((aws.access-key-id))
      aws_secret_access_key: ((aws.secret-access-key))
      aws_region: us-east-1
```

ECR tokens expire every 12 hours. The resource handles token refresh automatically.

---

### Push image after build, skip implicit download

```yaml
jobs:
  - name: build-and-push
    plan:
      - get: source
        trigger: true
      - task: build-image
        # produces build/image.tar
      - put: app-image
        no_get: true            # skip the implicit get — image is large; we don't need it back
        params:
          image: build/image.tar
          bump_aliases: true    # push 1.5.0, 1.5, and 1 tags
```

---

## Gotchas

- `tag: latest` — the resource checks for digest changes to the tag. A re-tagged image (same layers, different digest) will trigger. A rebuilt image with the same layers won't. Use `semver_constraint` for predictability.
- `pre_releases: true` is required for versions like `1.2.3-rc.1`. Note that `1.2.3-alpine` is treated as a _variant_, not a pre-release, unless the suffix starts with `alpha`, `beta`, or `rc`.
- `variant` (e.g. `alpine`) appends to the semver tag: `1.2.3-alpine`. Combine with `semver_constraint` to track `>=1.2 <2` in the alpine variant.
- `format: oci` in get params produces an OCI tar suitable for `docker load` or re-pushing. `format: rootfs` (default) unpacks the rootfs for use in tasks.
- `tag_regex` and `tag` are mutually exclusive. So are `tag_regex` and `semver_constraint`.
- AWS ECR: `aws_session_token` is needed only for assumed-role credentials. For static keys, `aws_access_key_id` + `aws_secret_access_key` + `aws_region` are enough.

---

## See also

- [core-types.md](core-types.md) — when registry-image vs other types
- [versioning.md](versioning.md) — digest pinning via pipeline-level `version:`
- [trigger-tuning.md](trigger-tuning.md) — `check_every`, `webhook_token` for image registries
- [custom-types.md](custom-types.md) — `image_resource` in tasks
