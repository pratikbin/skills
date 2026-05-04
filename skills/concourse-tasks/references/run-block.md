# run-block.md

Specifies the executable and arguments that run inside the task container. Required field.

## Schema

```yaml
run:
  path: bash           # required. executable. searched in PATH or absolute path.
  args:                # optional. list of strings passed to path
    - -ec
    - |
      cd source
      go build -o ../bin/app ./cmd/app
  dir: source          # optional. working directory relative to /tmp/build/<id>/
  user: nobody         # optional. run as this user. default: image USER or root
```

## `path` choices

Two patterns cover 99% of tasks:

### Inline script (one-liners, simple sequences)

```yaml
run:
  path: bash
  args:
    - -ec             # -e: exit on error. -c: read commands from string
    - |
      echo "building version $VERSION"
      cd source
      make build
```

`-e` makes Bash exit on first failure. Without it, `make build` failure is silently swallowed and the task succeeds. Always use `-e` or equivalent.

### Script in repo (complex logic, reusable, shellcheck-friendly)

```yaml
# task.yml
inputs:
  - name: source

run:
  path: source/ci/tasks/build/run.sh
```

```bash
#!/usr/bin/env bash
set -euo pipefail  # -u: unset vars are errors; -o pipefail: pipe fails propagate

cd source
go test ./...
go build -o ../bin/app ./cmd/app
```

Prefer scripts when:
- Logic is >10 lines.
- Same script is run locally during development.
- You want shellcheck in your editor.
- The task is reused across jobs.

## `dir`

Sets the working directory inside the container before executing `path`. Equivalent to `cd dir` before the run.

```yaml
inputs:
  - name: source

run:
  path: make
  args: [test]
  dir: source        # task runs "make test" from /tmp/build/<id>/source/
```

Without `dir`, the working directory is `/tmp/build/<id>/` (the task root). All input paths are relative to that root.

## `user`

```yaml
run:
  path: bash
  args: [-c, "whoami && id"]
  user: ci-runner    # must exist in the image
```

Defaults to the image's `USER` instruction. Override to drop privileges (e.g., run as `nobody` after setup that required root). Rarely needed when images are purpose-built.

## Exit codes and failure

Concourse interprets non-zero exit as task failure. The task step turns red. Downstream steps with `on_failure:` trigger.

```yaml
run:
  path: bash
  args:
    - -ec
    - |
      cd source
      go test ./...          # exits non-zero on test failure → task fails
      go build ./cmd/app
```

Common pitfall: forgetting `-e` on inline bash. `set -e` inside the heredoc doesn't help if the outermost shell doesn't propagate it.

## Best practices

- Scripts over inline args for anything > ~5 lines.
- `#!/usr/bin/env bash` + `set -euo pipefail` in every script.
- Keep script in `ci/tasks/<task-name>/run.sh` alongside `task.yml`.
- Run `shellcheck ci/tasks/*/run.sh` in a lint task.
- Use `run.dir:` instead of `cd` at the top of inline args — cleaner.

## Example — script in repo with dir

```yaml
# ci/tasks/test.yml
platform: linux

image_resource:
  type: registry-image
  source:
    repository: golang
    tag: "1.22"
  version:
    digest: "sha256:abc123..."

inputs:
  - name: source

caches:
  - path: pkg/mod

run:
  path: source/ci/tasks/test/run.sh
  # no dir needed; script navigates itself
```

```bash
# ci/tasks/test/run.sh
#!/usr/bin/env bash
set -euo pipefail

cd source
export GOPATH=/tmp/build/put   # align with cache path
go test -count=1 -race ./...
```

## Gotchas

- `path: sh` vs `path: bash`: `sh` is POSIX, not Bash. `[[`, `${var:-default}`, arrays all fail.
- `args` items are individual tokens. Do not write `args: ["-ec 'go build'"]` — that's one arg with spaces, not two.
- `run.path` must be an executable (mode 0755). Scripts checked out from git usually are if committed with execute bit.
- `run.user` must exist in the image. Setting a non-existent user causes container start failure.

## See also

- `schema.md` — run block in full task config
- `debugging.md` — `fly execute` to run a task with its script locally
- `anti-patterns.md` — inline config when script should be in repo
