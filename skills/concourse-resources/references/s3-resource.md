# s3-resource.md — `s3` resource type schema and patterns

Upload and download files from S3 or any S3-compatible object store. Version tracking via S3 versioning or filename regexp.

---

## Schema

```yaml
resources:
  - name: release-tarball
    type: s3
    source:
      bucket: my-release-bucket          # required
      access_key_id: ((aws.key-id))       # optional; falls back to env/instance role
      secret_access_key: ((aws.secret))   # optional
      session_token: ((aws.session))      # optional; for assumed-role creds
      region_name: us-east-1             # optional; default us-east-1
      endpoint: https://s3.example.com   # optional; S3-compatible endpoint
      disable_ssl: false                 # optional; skip TLS (dev only)
      skip_ssl_verification: false       # optional; ignore cert errors
      ca_bundle: ((custom-ca))           # optional; PEM bundle for private CA
      use_path_style: false              # optional; force path-style URLs (MinIO, Ceph)
      skip_s3_checksums: false           # optional; skip ETag validation
      disable_multipart: false           # optional; disable multipart upload (some compat issues)
      cloudfront_url: https://cdn.example.com  # optional; serve downloads via CloudFront

      # Choose ONE of the following:

      # Option A: regexp — version tracked by filename capture group
      regexp: releases/myapp-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz

      # Option B: versioned_file — version tracked by S3 object versioning
      # versioned_file: releases/myapp-latest.tar.gz

      # Option C: fixed path — no version tracking; always gets the same object
      # path: configs/static-config.json
```

`regexp` and `versioned_file` are mutually exclusive. Use `regexp` when filenames embed the version. Use `versioned_file` when you overwrite a fixed key and need S3's version history.

---

## `get` params

```yaml
- get: release-tarball
  params:
    skip_download: false        # optional; record the version without downloading bytes
    expected_sha256: abc123     # optional; verify download hash
    expected_size: 10485760     # optional; verify download size in bytes (fails if mismatch)
    unpack: false               # optional; untar/unzip after download
```

---

## `put` params

```yaml
- put: release-tarball
  params:
    file: build/myapp-*.tar.gz          # required; local path glob to upload
    acl: private                        # optional; private | public-read | etc.
    content_type: application/x-tar     # optional; override Content-Type header
    cache_control: no-cache             # optional; Cache-Control header
    content_encoding: gzip              # optional
    content_disposition: attachment     # optional
    copy_tags_from_file: tags.json      # optional; JSON key-value map of S3 object tags
```

When using `regexp`, the version is extracted from the uploaded filename. The regexp capture group must match the version portion.

---

## Examples

### Tarball publish and download-only on deploy

```yaml
resources:
  - name: app-release
    type: s3
    source:
      bucket: my-releases
      regexp: builds/myapp-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz
      access_key_id: ((aws.key-id))
      secret_access_key: ((aws.secret))
      region_name: us-east-1

jobs:
  - name: build
    plan:
      - get: source
        trigger: true
        passed: [test]
      - task: build-tarball
        # produces build/myapp-1.2.3.tar.gz
      - put: app-release
        params:
          file: build/myapp-*.tar.gz

  - name: deploy
    plan:
      - get: app-release
        trigger: true
        passed: [build]
        params:
          skip_download: false    # actually download the tarball for deploy
      - task: deploy-app
        # uses app-release/myapp-1.2.3.tar.gz
```

---

### S3 versioned file — overwrite fixed key, track via S3 versioning

```yaml
resources:
  - name: config-file
    type: s3
    source:
      bucket: my-config-bucket
      versioned_file: configs/app-config.json
      region_name: eu-west-1
      access_key_id: ((aws.key-id))
      secret_access_key: ((aws.secret))

jobs:
  - name: update-config
    plan:
      - task: generate-config
        # produces output/app-config.json
      - put: config-file
        params:
          file: output/app-config.json

  - name: apply-config
    plan:
      - get: config-file
        trigger: true
        passed: [update-config]
      - task: apply
        # uses config-file/app-config.json
```

Requires S3 bucket versioning to be enabled.

---

### S3-compatible endpoint (MinIO)

```yaml
resources:
  - name: artifact
    type: s3
    source:
      bucket: ci-artifacts
      regexp: artifacts/build-([0-9]+)\.zip
      endpoint: http://minio.internal:9000
      use_path_style: true          # MinIO requires path-style
      disable_ssl: true             # internal cluster, no TLS
      access_key_id: ((minio.key))
      secret_access_key: ((minio.secret))
```

---

### skip_download for heavy artifacts on notification jobs

```yaml
jobs:
  - name: notify-on-release
    plan:
      - get: app-release
        trigger: true
        passed: [build]
        params:
          skip_download: true   # we only need the version number, not the bytes
      - task: send-notification
        # reads version from app-release/version (or app-release/.metadata)
```

`skip_download: true` records the version metadata without transferring the file. Saves bandwidth when a downstream job only needs the version string.

---

## Gotchas

- `regexp` must contain exactly one capture group (the version). Extra groups cause unexpected behavior.
- `versioned_file` requires the S3 bucket to have versioning enabled. Without it, every put overwrites silently and `check` always returns one version.
- Files uploaded with `regexp` must have the version string embedded in the filename; the regex is matched against the object key (full path).
- `use_path_style: true` is required for MinIO, Ceph, and some other S3-compatible stores that don't support virtual-hosted-style URLs.
- `disable_multipart: true` is needed for some providers (e.g. old Ceph versions) that don't support multipart upload. Large files may be slower without multipart.
- `cloudfront_url` only affects downloads (get); uploads still go directly to S3.
- AWS session tokens expire; for long-running pipelines use IAM roles attached to worker instances rather than static keys.

---

## See also

- [versioning.md](versioning.md) — `version:` pinning, `passed:` chains
- [semver-resource.md](semver-resource.md) — s3 driver for version files
- [trigger-tuning.md](trigger-tuning.md) — `check_every` for artifact buckets
- [anti-patterns.md](anti-patterns.md) — missing `no_get: true` on large puts
