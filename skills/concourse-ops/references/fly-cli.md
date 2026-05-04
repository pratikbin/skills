# fly CLI reference

Full command reference for `fly`, the Concourse CLI. Always use `-t <target>` (alias for `--target`).

## Targeting / login

```bash
# login — opens browser or prompts for basic creds
fly -t prod login -c https://ci.example.com -n my-team

# login non-interactively (CI, local user)
fly -t prod login -c https://ci.example.com -u admin -p secret -n main

# list all saved targets
fly targets

# logout one target
fly -t prod logout

# logout all targets
fly logout -a
```

`fly targets` shows URL, team, token expiry. Tokens stored in `~/.flyrc`.

## Pipelines

```bash
# set pipeline (create or update)
fly -t prod set-pipeline -p my-pipeline -c pipeline.yml

# load vars from file(s)
fly -t prod set-pipeline -p my-pipeline -c pipeline.yml \
    -l vars.yml -l secrets.yml

# inline var override
fly -t prod set-pipeline -p my-pipeline -c pipeline.yml -v key=value

# non-interactive (skip diff prompt, useful in CI)
fly -t prod set-pipeline -p my-pipeline -c pipeline.yml -y

# set an instanced pipeline
fly -t prod set-pipeline -p my-pipeline -c pipeline.yml \
    -i branch=main

# get current config (YAML)
fly -t prod get-pipeline -p my-pipeline

# list pipelines
fly -t prod pipelines

# pause / unpause
fly -t prod pause-pipeline -p my-pipeline
fly -t prod unpause-pipeline -p my-pipeline

# archive — keeps pipeline visible but stops scheduling; config deleted
fly -t prod archive-pipeline -p my-pipeline

# destroy — removes permanently
fly -t prod destroy-pipeline -p my-pipeline

# validate without uploading
fly -t prod validate-pipeline -c pipeline.yml

# auto-format pipeline YAML in-place
fly -t prod format-pipeline -c pipeline.yml -w

# expose pipeline to the public internet (no auth required to view)
fly -t prod expose-pipeline -p my-pipeline

# hide again
fly -t prod hide-pipeline -p my-pipeline

# rename
fly -t prod rename-pipeline -o old-name -n new-name

# order pipelines on dashboard
fly -t prod order-pipelines -p pipe-a -p pipe-b -p pipe-c
```

## Jobs / builds

```bash
# list jobs in a pipeline
fly -t prod jobs -p my-pipeline

# list builds (recent 10 by default)
fly -t prod builds -j my-pipeline/my-job

# trigger a job
fly -t prod trigger-job -j my-pipeline/my-job

# trigger and stream output
fly -t prod trigger-job -j my-pipeline/my-job -w

# watch a running build
fly -t prod watch -j my-pipeline/my-job

# watch a specific build number
fly -t prod watch -j my-pipeline/my-job -b 42

# pause / unpause job
fly -t prod pause-job -j my-pipeline/my-job
fly -t prod unpause-job -j my-pipeline/my-job

# abort a running build
fly -t prod abort-build -j my-pipeline/my-job -b 42
```

## Resources

```bash
# force a resource check (from tip)
fly -t prod check-resource -r my-pipeline/my-resource

# check from a specific version
fly -t prod check-resource -r my-pipeline/my-resource \
    --from ref:abc123

# check a resource type (not a resource)
fly -t prod check-resource-type -r my-pipeline/my-type

# clear cached resource versions (forces re-check from zero)
fly -t prod clear-resource-cache -r my-pipeline/my-resource
```

## Debugging

```bash
# intercept into a running/failed build step container
fly -t prod intercept -j my-pipeline/my-job -s build -b 42

# intercept shorthand (latest build, first step)
fly -t prod intercept -j my-pipeline/my-job

# `hijack` is an alias for `intercept`
fly -t prod hijack -j my-pipeline/my-job -s build

# run a local task (one-off build)
fly -t prod execute -c task.yml

# with inputs/outputs
fly -t prod execute -c task.yml -i source=./src -o artifacts=./out

# stream the one-off build log
fly -t prod execute -c task.yml -i source=./src -w
```

`fly execute` does NOT read caches. Use a real job to test `caches:` behavior.

## Workers

```bash
# list workers and state
fly -t prod workers

# remove a stalled worker (must be in 'stalled' or 'landed' state)
fly -t prod prune-worker -w worker-name

# prune all stalled workers at once
fly -t prod prune-worker --all-stalled
```

## Users

```bash
# show info about current logged-in user
fly -t prod userinfo

# list users with recent activity (admin only)
fly -t prod active-users
```

## Helpers

```bash
# update fly binary to match the targeted ATC version
fly -t prod sync

# shell completion (bash example)
fly completion --shell bash >> ~/.bashrc
```

## Gotchas

- `-y` / `--non-interactive` skips the diff prompt but still requires the diff to be computed. Errors in YAML surface here.
- `archive-pipeline` deletes the stored config; `fly get-pipeline` will error on archived pipelines.
- `fly execute` ignores `caches:` and any resource triggers. Purely ad-hoc.
- `fly intercept` without `-b` targets the most recent build. Add `-b` to target a specific one.
- `fly sync` must target an ATC; it downloads the binary matching the server version.

## See also

- `references/set-pipeline-step.md` — automated pipeline reconfiguration via `set_pipeline`
- `references/instance-pipelines.md` — instanced pipeline management
- `references/debugging-stuck.md` — `intercept`, `check-resource`, `prune-worker` in context
