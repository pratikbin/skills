# core-types.md — when to pick which built-in resource type

Quick reference for the six most-used built-in types plus `mock` for test pipelines. Pick the narrowest type that fits.

---

## Comparison table

| type | purpose | use when | watch out for |
|---|---|---|---|
| `git` | track commits, tags, or paths in a git repo | any source code trigger; monorepos with `paths`; tag-only releases | triggers on every commit unless `paths`/`tag_filter` are set; shallow clone (`depth`) breaks `git describe` |
| `time` | emit a version on a schedule or within a window | nightly builds, rate-limited jobs, business-hours-only triggers | every tick is a new version — `trigger: true` fires the job on **every** tick, not once; see [time-resource.md](time-resource.md) |
| `registry-image` | track or push OCI images | fetching base images, pushing build output, pinning by digest or semver constraint | `tag: latest` is opaque — image changes silently; always pin or constrain |
| `semver` | manage a single monotonically-increasing semantic version | release automation, coordinating version bumps across jobs | `put` step cannot be a job trigger; `passed:` not allowed on `put` step |
| `s3` | store and retrieve files from S3-compatible storage | build artifacts, release tarballs, deployment packages | `regexp` and `versioned_file` are mutually exclusive; `regexp` enables version tracking |
| `pool` | coordinate exclusive access to a shared resource | environment serialization, finite license slots, manual approval gates | backed by a git repo — adds latency; repo contention under heavy concurrency |
| `mock` | emit synthetic versions for pipeline testing | CI tests of the pipeline itself, local `fly execute` dry-runs | never use in production pipelines; emits fake versions that look real |

---

## git

One-line purpose: track commits or tags in a git repo and fetch the working tree.

Use when:
- You need to trigger on source changes.
- You need to scope triggers to a subtree in a monorepo.
- You need tag-based release versioning.

Watch out for:
- Without `paths`, every commit triggers every consumer. In a monorepo, always set `paths` or `ignore_paths`.
- `depth: 1` speeds up clones but breaks operations that need history (git log, git describe, signed commits).
- `tag_filter` is a glob, not a regex.

See [git-resource.md](git-resource.md) for full schema.

---

## time

One-line purpose: emit a version on a schedule or within a time window.

Use when:
- You need a cron-style trigger (nightly, weekly, business hours only).
- You need to rate-limit how often a downstream job can run.

Watch out for:
- `interval: 1m` with `trigger: true` fires the job every minute. Heavy jobs will queue up.
- Time windows (`start`/`stop`) only allow one tick per window entry, not one per minute inside the window.
- `initial_version: true` allows manual runs before the first tick.

See [time-resource.md](time-resource.md).

---

## registry-image

One-line purpose: check, fetch, and push OCI-compatible container images.

Use when:
- Fetching a base image for use in a task's `image_resource`.
- Pushing a built image to a registry.
- Pinning to a specific digest or tracking semver tags.

Watch out for:
- `tag: latest` is mutable — image changes without a new version if the digest changes after pinning. Use digest pinning or `semver_constraint`.
- Multi-arch: set `platform.os` / `platform.architecture` explicitly when the registry serves a manifest list.
- AWS ECR credentials expire; use `aws_access_key_id` + `aws_secret_access_key` or IAM instance roles.

See [registry-image.md](registry-image.md).

---

## semver

One-line purpose: store and bump a single semantic version number in a persistent backend (git, S3, GCS, swift).

Use when:
- Release pipelines that need to atomically bump major/minor/patch/pre.
- Coordinating version numbers across multiple put steps.

Watch out for:
- `put` step cannot trigger a job (`trigger:` on `put` is invalid).
- `passed:` is not allowed on a `put` step.
- The git driver stores the version in a dedicated branch; don't use your main source branch.

See [semver-resource.md](semver-resource.md).

---

## s3

One-line purpose: upload and download files from S3 or S3-compatible storage.

Use when:
- Storing build artifacts between jobs.
- Publishing release tarballs.
- Downloading large files only when needed (use `skip_download`).

Watch out for:
- Use `versioned_file` for S3 versioning (requires S3 versioning enabled on the bucket).
- Use `regexp` for version-numbered filenames; the regex capture group becomes the version.
- `versioned_file` and `regexp` are mutually exclusive.

See [s3-resource.md](s3-resource.md).

---

## pool

One-line purpose: claim/release named locks from a git-backed lock repository.

Use when:
- Serializing access to a shared environment (only one deploy at a time).
- Implementing a manual approval gate.
- Managing a finite set of licenses or seats.

Watch out for:
- Every lock operation is a git commit — slow (seconds). Not suitable for sub-second coordination.
- Lock repo contention under heavy parallelism causes retries.
- The lock repo must be pre-populated with lock files in `pool/<name>/unclaimed/`.

See [pool-resource.md](pool-resource.md).

---

## mock

One-line purpose: emit a configurable synthetic version for pipeline testing without real external dependencies.

Use when:
- Writing pipeline integration tests (`fly execute`).
- Testing `passed:` chains and trigger logic without real resources.

Watch out for:
- `mock` versions are not real. Never use in a production pipeline that deploys real software.
- Requires the `mock` resource type to be declared in `resource_types` (it is not a built-in).

---

## See also

- [schema.md](schema.md) — `resource{}` and `resource_type{}` top-level fields
- [git-resource.md](git-resource.md)
- [registry-image.md](registry-image.md)
- [time-resource.md](time-resource.md)
- [semver-resource.md](semver-resource.md)
- [s3-resource.md](s3-resource.md)
- [pool-resource.md](pool-resource.md)
- [custom-types.md](custom-types.md) — when none of the above fit
