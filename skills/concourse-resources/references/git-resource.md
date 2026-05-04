# git-resource.md — `git` resource type schema and patterns

Tracks commits or tags in a git repository; fetches the working tree on `get`; commits + pushes on `put`.

---

## Schema

```yaml
resources:
  - name: my-repo
    type: git
    source:
      uri: https://github.com/example/repo.git   # required; HTTP(S) or SSH URI
      branch: main                                # required for check/get (unless tag_filter set)
      private_key: ((git.private-key))            # optional; SSH private key (PEM)
      username: ((git.username))                  # optional; HTTP basic auth
      password: ((git.password))                  # optional; HTTP basic auth or token
      paths:                                      # optional; only trigger on these path globs
        - src/**
        - go.mod
      ignore_paths:                               # optional; never trigger on these path globs
        - "**/*.md"
        - docs/**
      tag_filter: "v[0-9]*"                       # optional; glob; check only matching tags
      tag_regex: "^v[0-9]+\\.[0-9]+"             # optional; regex alternative to tag_filter
      fetch_tags: false                           # optional; fetch all tags on get
      depth: 0                                    # optional; 0 = full history; N = shallow clone
      submodules: all                             # optional; all | none | list of paths
      submodule_recursive: true                   # optional; recursively init submodules
      submodule_remote: false                     # optional; use submodule remote tracking branch
      disable_ci_skip: false                      # optional; if true, do not skip [ci skip] commits
      clean_tags: false                           # optional; delete local tags before fetch
      git_crypt_key: ((git-crypt.key))            # optional; base64-encoded git-crypt key
      commit_filter:                              # optional; filter commits by message content
        include:
          - "deploy"
        exclude:
          - "WIP"
      git_config:                                 # optional; key/value git config to set locally
        - name: user.email
          value: ci@example.com
        - name: user.name
          value: CI Bot
      short_ref_format: "%s"                      # optional; format for short_ref metadata
      https_tunnel:                               # optional; proxy HTTPS via a CONNECT proxy
        proxy_host: proxy.internal
        proxy_port: "3128"
```

### `get` params

```yaml
- get: my-repo
  params:
    depth: 1              # optional; override source depth for this get
    submodules: none      # optional; override source submodules for this get
    submodule_recursive: false
    disable_git_lfs: false
    clean_tags: true
    short_paths: false    # optional; return only short paths in changed_files
```

### `put` params

```yaml
- put: my-repo
  params:
    repository: built-repo          # required; path to the git repo to push
    branch: main                    # optional; branch to push to (defaults to source.branch)
    tag: version/number             # optional; path to file containing the tag name
    tag_prefix: "v"                 # optional; prefix prepended to the tag value
    annotate: release-notes/body    # optional; path to file with annotation body
    force: false                    # optional; force push
    merge: false                    # optional; merge instead of rebase before push
    notes: release-notes/body       # optional; path to git notes content
    rebase: false                   # optional; rebase before push
    only_tag: false                 # optional; push only the tag, not the branch commit
```

---

## Examples

### Monorepo path filter — only trigger on changed service paths

```yaml
resources:
  - name: orders-src
    type: git
    source:
      uri: https://github.com/example/monorepo.git
      branch: main
      paths:
        - services/orders/**
        - libs/shared/**
      ignore_paths:
        - "**/*.md"
        - "**/*.txt"
        - docs/**

jobs:
  - name: test-orders
    plan:
      - get: orders-src
        trigger: true
```

Only commits that touch `services/orders/` or `libs/shared/` (excluding docs) will trigger `test-orders`.

---

### Tag-only release trigger

```yaml
resources:
  - name: release-tag
    type: git
    check_every: 1h           # release tags are rare; slow down polling
    source:
      uri: https://github.com/example/app.git
      tag_filter: "v[0-9]*.[0-9]*.[0-9]*"
      # no branch needed when tag_filter is set

jobs:
  - name: publish-release
    plan:
      - get: release-tag
        trigger: true
      - task: build-release
        # ...
```

`check` emits one version per matching tag. `get` checks out the tagged commit.

---

### Shallow clone for speed

```yaml
resources:
  - name: app-src
    type: git
    source:
      uri: https://github.com/example/large-repo.git
      branch: main
      depth: 1                # only the tip commit; fast clone

jobs:
  - name: lint
    plan:
      - get: app-src
        trigger: true
        params:
          depth: 1
      - task: run-lint
        # ...
```

Trade-off: `depth: 1` breaks `git log`, `git describe`, and anything needing commit ancestry.

---

### [ci skip] integration

```yaml
resources:
  - name: docs-repo
    type: git
    source:
      uri: https://github.com/example/docs.git
      branch: main
      disable_ci_skip: false  # default; commits with [ci skip] or [skip ci] are skipped
```

Set `disable_ci_skip: true` to always process every commit regardless of message.

---

## Gotchas

- `paths` and `ignore_paths` are evaluated on the diff between the previous check version and the new commit. A brand-new resource with no prior version will trigger once regardless of paths.
- `tag_filter` is a shell glob (`v[0-9]*`), not a regex. For regex matching use `tag_regex`.
- `fetch_tags: true` fetches all tags on every `get`, which can be slow on repos with thousands of tags.
- `clean_tags: true` deletes local tags before fetching — needed when upstream tags are force-pushed (rare but prevents stale refs).
- `git_crypt_key` must be base64-encoded. Decode is done inside the container at checkout time.
- Shallow clone (`depth: N`) + `put` with a tag can fail if the referenced commit isn't in the shallow history.
- `commit_filter.exclude` patterns are matched against the commit message; commits matching any exclude pattern are never emitted, even if they match an include pattern.

---

## See also

- [trigger-tuning.md](trigger-tuning.md) — `check_every`, `webhook_token`, path scoping
- [versioning.md](versioning.md) — `version: every`, `passed:`, `trigger:`
- [core-types.md](core-types.md) — when to use git vs other types
