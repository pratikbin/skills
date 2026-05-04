# debugging.md

Two tools: `fly execute` runs a task locally; `fly intercept` drops a shell into a running or failed container.

## `fly execute` — run a task locally

```
fly -t <target> execute -c task.yml [flags]
```

Key flags:

| Flag | Meaning |
|---|---|
| `-c task.yml` | Task config file to run |
| `-i name=path` | Bind a local directory as a named input |
| `-o name=path` | Extract a named output to a local directory after run |
| `--image name` | Use a `registry-image` resource already fetched in a job (overrides image_resource) |
| `--inputs-from pipeline/job` | Pull inputs from the latest build of a pipeline job instead of local dirs |
| `-v key=value` | Set a var `((key))` to `value` (credential manager not used) |
| `-l vars.yml` | Load vars from a YAML file |

### Basic example

```shell
# Run build task, bind local source dir as "source" input
fly -t ci execute -c ci/tasks/build.yml -i source=.
```

### With output extraction

```shell
fly -t ci execute \
  -c ci/tasks/build.yml \
  -i source=. \
  -o bin=./local-bin
# ./local-bin/ contains the built artifact after task exits
```

### With var override (no credential manager)

```shell
fly -t ci execute \
  -c ci/tasks/deploy.yml \
  -i source=. \
  -v deploy_env=staging \
  -l local-secrets.yml     # git-ignored vars file
```

### Reproduce a pipeline failure locally

```shell
# Grab inputs from the last failing build of the "test" job
fly -t ci execute \
  -c ci/tasks/test.yml \
  --inputs-from my-pipeline/test
```

Concourse streams the exact input versions from the failed build. Same inputs, same image, same params. If it fails locally, you can iterate fast.

## `fly intercept` — shell into a container

Drops a shell into a task container that is currently running or that just failed (containers linger briefly after failure).

```
fly -t <target> intercept -j pipeline/job -b build-number -s step-name
```

Key flags:

| Flag | Meaning |
|---|---|
| `-j pipeline/job` | Job to intercept |
| `-b build-number` | Build number (omit for latest) |
| `-s step-name` | Step name to enter (omit to get a menu) |
| `--` | Everything after `--` is the command to run inside the container |

### Examples

```shell
# Enter the latest failed build of "unit-test" step in "test" job
fly -t ci intercept -j my-pipeline/test -s unit-test

# Run a specific command instead of interactive shell
fly -t ci intercept -j my-pipeline/build -s compile -- env | sort

# Inspect a specific old build
fly -t ci intercept -j my-pipeline/test -b 42 -s unit-test

# Without -s, fly shows a menu of available containers
fly -t ci intercept -j my-pipeline/test
```

### What you can do inside

```shell
# Check env vars
env | grep -i token

# Verify input contents
ls -la /tmp/build/*/source/

# Re-run the failing command manually
bash -x ci/tasks/test/run.sh

# Check what files are in the output dir
ls -la /tmp/build/*/bin/
```

## Workflow: "task fails on push, works locally"

1. Check CI build output for error message and exit code.
2. `fly execute -c ci/tasks/failing-task.yml --inputs-from pipeline/job` — reproduce with exact inputs.
3. If it also fails locally: fix the script, re-run, iterate.
4. If it passes locally but fails in CI: environment difference. Check params, env vars.
   ```shell
   fly -t ci intercept -j pipeline/job -s failing-step -- env | sort > /tmp/ci-env.txt
   # compare with local env
   ```
5. `fly intercept` into the failed container — navigate, inspect, run commands manually.
6. Once root cause identified, fix task.yml or run script. Push and verify.

## Gotchas

- `fly intercept` window is short. Concourse GCs containers after a few minutes. Intercept immediately after failure.
- One-off `fly execute` builds don't use pipeline caches. Cold run may expose cache-dependency bugs.
- `fly execute` doesn't connect to the credential manager. Use `-v` or `-l` for local secret simulation.
- Interactive `-s` menu is alphabetical, not run-order. Know your step name.
- `fly intercept` into an on-success/on-failure hook step requires knowing the hook step's name.

## See also

- `run-block.md` — scripts in repo are easier to test locally
- `params-vs-vars.md` — `fly execute --var` for local credential simulation
- `caches.md` — `fly execute` ignores caches
