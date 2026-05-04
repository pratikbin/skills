# Fixing Silent Breakage from `latest` Tag in Concourse registry-image Resource

## The Problem

Your current config uses `tag: latest`, which means Concourse will pull whatever is currently tagged `latest` on Docker Hub. When an upstream maintainer pushes a breaking change to that tag, your pipelines break without warning. You get no notification, no pin, no way to roll back cleanly.

## Option 1: Semver Constraint (Recommended for your use case)

```yaml
resources:
  - name: golang-builder
    type: registry-image
    source:
      repository: golang
      tag: 1.22
      username: ((dockerhub.username))
      password: ((dockerhub.password))
```

Docker Hub's official Go image uses floating minor tags. The tag `1.22` always points to the latest patch in the 1.22.x line. When Go 1.22.5 is released, the `1.22` tag is updated — you pick it up automatically on the next check. When Go 1.23 ships, the `1.22` tag is NOT updated — you stay on 1.22.x.

To make patch pickup explicit and auditable, use the semver variant with a more specific tag format:

```yaml
resources:
  - name: golang-builder
    type: registry-image
    source:
      repository: golang
      tag: "1.22"
      username: ((dockerhub.username))
      password: ((dockerhub.password))
    check_every: 6h
```

This is the pragmatic middle ground: you auto-receive patch releases (security fixes, bug fixes) while being protected from minor/major version jumps.

## Option 2: Digest Pinning (Maximum Reproducibility)

```yaml
resources:
  - name: golang-builder
    type: registry-image
    source:
      repository: golang
      digest: sha256:a1b2c3d4e5f6...   # exact image digest
      username: ((dockerhub.username))
      password: ((dockerhub.password))
```

Or, capture the digest after a known-good build and pin it:

```yaml
resources:
  - name: golang-builder
    type: registry-image
    source:
      repository: golang
      tag: "1.22.4"     # exact patch version tag
      username: ((dockerhub.username))
      password: ((dockerhub.password))
```

With digest pinning, every build uses exactly the same image bytes. No surprises, ever. The tradeoff: you must manually bump the digest/tag to pick up security patches. If you forget, you accumulate CVEs silently.

## Tradeoff Summary

| Approach | Reproducibility | Auto-patches | Risk |
|---|---|---|---|
| `tag: latest` | None | Yes (all versions) | Silent breaking changes (your current problem) |
| `tag: "1.22"` (floating minor) | Medium | Yes (patch only) | Patch releases can still break; you get notice via failed build |
| `tag: "1.22.4"` (exact patch) | High | No | CVEs accumulate; manual toil to update |
| `digest: sha256:...` | Maximum | No | Same as exact patch, plus image layers are immutable |

## Recommended Configuration

For your stated requirements (go 1.22.x, auto-patches, no 1.23 jump):

```yaml
resources:
  - name: golang-builder
    type: registry-image
    source:
      repository: golang
      tag: "1.22"
      username: ((dockerhub.username))
      password: ((dockerhub.password))
    check_every: 6h
```

**Why this works:**
- The `1.22` floating tag on Docker Hub's official golang image tracks 1.22.x patches only.
- You automatically pick up `1.22.5`, `1.22.6`, etc., as they are released.
- Go 1.23 will never be pulled — it gets its own `1.23` tag.
- `check_every: 6h` controls polling frequency; adjust to your security SLA.

**Remaining risk:** A patch release itself could contain a breaking change (rare for Go, but possible). If you need stronger guarantees, add a staging pipeline stage that validates the new image before it reaches prod. Use Concourse's `passed` constraint to gate promotion:

```yaml
jobs:
  - name: build-staging
    plan:
      - get: golang-builder
        trigger: true
      # ... build and test in staging

  - name: build-prod
    plan:
      - get: golang-builder
        passed: [build-staging]   # only use image that passed staging
        trigger: true
      # ... deploy to prod
```

This gives you automatic patch pickup with a validation gate — patches only reach prod after staging confirms they don't break your app.
