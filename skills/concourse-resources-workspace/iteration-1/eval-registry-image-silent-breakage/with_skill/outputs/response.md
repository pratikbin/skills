# Fixing `tag: latest` Silent Breakage for golang-builder

## The Problem

`tag: latest` is a mutable pointer. When DockerHub rebuilds `golang:latest`, Concourse detects the new digest and triggers your jobs. Two builds on the same day may use entirely different images — no diff in your pipeline config, no warning, instant breakage.

---

## Recommended Solution: `semver_constraint` to track Go 1.22.x patches

```yaml
resources:
  - name: golang-builder
    type: registry-image
    check_every: 4h          # DockerHub doesn't support webhooks; polling is fine
    source:
      repository: golang
      semver_constraint: ">=1.22 <1.23"   # auto-picks 1.22.1, 1.22.2, ..., stops before 1.23
      username: ((dockerhub.username))
      password: ((dockerhub.password))
```

When DockerHub publishes `golang:1.22.4`, Concourse's next check emits it as a new version and triggers your jobs. When `golang:1.23.0` appears, the constraint rejects it — your pipeline stays on the 1.22.x train.

> **Note on variants**: If you need `golang:1.22-alpine3.20` or similar, add `variant: alpine3.20`. The `semver_constraint` applies to the numeric portion; the variant is appended automatically.

---

## Alternative: Digest Pinning (Maximum Reproducibility)

```yaml
resources:
  - name: golang-builder
    type: registry-image
    check_every: never        # will not update unless you change the config
    source:
      repository: golang
      tag: "1.22.3"           # explicit patch tag
      username: ((dockerhub.username))
      password: ((dockerhub.password))
    version:
      digest: "sha256:<digest-of-1.22.3>"  # byte-identical across all builds
```

This is the most reproducible option. Two builds a year apart use the exact same image bytes. Updates require a deliberate pipeline config change — no surprises.

---

## Tradeoff Comparison

| Approach | Reproducibility | Auto-picks patches | Effort to update |
|---|---|---|---|
| `tag: latest` | None — silent breakage | Yes (uncontrolled) | Zero |
| `semver_constraint: ">=1.22 <1.23"` | Good — stays on a known major.minor | Yes (patch only) | None for patches; manual bump to 1.23 |
| Digest pin (`version: digest: sha256:...`) | Perfect — byte-identical | No | Manual: update digest in pipeline config |

---

## Recommendation

For your use case — **auto-pick Go 1.22.x patches, never jump to 1.23** — use `semver_constraint`. It gives you:

- Security patches without manual intervention
- Protection against accidental major/minor bumps
- A clear, auditable constraint in your pipeline config

If you ever need a full audit trail for a specific build (compliance, incident post-mortem), note the `version.digest` emitted by the `get` step in the build log. You can replay that exact build by pinning to that digest temporarily.

The digest pin approach is best suited for air-gapped environments, highly regulated pipelines, or cases where you want the bump to be a deliberate, reviewed change — at the cost of receiving security patches only as fast as someone updates the config.
