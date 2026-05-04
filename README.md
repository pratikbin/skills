# pratikbin/skills

Curated [Agent Skills](https://docs.claude.com/en/docs/claude-code/skills) for [Claude Code](https://claude.com/claude-code) and any other [skills.sh](https://skills.sh)-compatible agent.

Personal skill packs, kept public. Currently ships **Uncloud** (4 skills), **Go optimizations** (perf playbook), and **Concourse CI** (4 skills). All in the same flat layout.

## Skills

### Uncloud

[Uncloud](https://github.com/psviderski/uncloud) is a lightweight single-binary orchestrator that turns a handful of VPS machines into a WireGuard-meshed cluster with Caddy-fronted services. These skills make Claude Code fluent in it.

| Skill | Purpose |
|---|---|
| [`uncloud-cluster`](skills/uncloud-cluster/SKILL.md) | Install Uncloud, bootstrap clusters, add/remove machines, manage contexts, reserve managed domains, configure WireGuard endpoints. |
| [`uncloud-compose`](skills/uncloud-compose/SKILL.md) | Author `compose.yaml` for Uncloud. Covers `x-ports`, `x-caddy`, `x-machines`, `x-pre_deploy`, replicated vs global mode, health checks, rollbacks, image tag templates. |
| [`uncloud-deploy`](skills/uncloud-deploy/SKILL.md) | `uc deploy`, `uc run`, `uc build`, `uc image push`. Rolling updates, health gating, private registries, CI/CD recipes, targeting contexts/machines. |
| [`uncloud-ops`](skills/uncloud-ops/SKILL.md) | Day-2: `uc ps`, `uc logs`, `uc exec`, `uc scale`, Caddy inspection, WireGuard debugging, volume management, 502 triage. |

### Concourse CI

[Concourse CI](https://concourse-ci.org) is a pipeline-as-code CI/CD system. These four skills make Claude Code fluent in writing **fast, idiomatic** Concourse pipelines. Speed-biased throughout (parallelism, caches, trigger tuning, credential caching). Grounded in concourse/docs and concourse/ci real-world pipelines.

| Skill | Purpose |
|---|---|
| [`concourse-pipeline`](skills/concourse-pipeline/SKILL.md) | `pipeline.yml` authoring: jobs, plans, all step types and modifiers/hooks, parallelism patterns, `passed:` chains, `serial`/`max_in_flight`, YAML anchors, anti-patterns. |
| [`concourse-resources`](skills/concourse-resources/SKILL.md) | Resources + resource types: schema, core types (git, registry-image, time, semver, s3, pool), versioning, trigger tuning (`paths`/`check_every`/`webhook_token`), custom types, global resources. |
| [`concourse-tasks`](skills/concourse-tasks/SKILL.md) | Task config: schema, pure-function model, `image_resource` pinning, `inputs`/`outputs` (incl. `input_mapping`/`output_mapping`), `caches:`, cache-as-task pattern, oci-build-task with buildkit cache, debugging via `fly intercept`/`fly execute`. |
| [`concourse-ops`](skills/concourse-ops/SKILL.md) | Day-2 + meta: `fly` CLI, `set_pipeline` step + instance pipelines, vars/`var_sources` and credential managers (Vault, AWS, K8s, CredHub, IDToken/OIDC), teams/auth, performance tuning, container placement, OPA, observability, "stuck job/check" debugging. |

### Go optimizations

| Skill | Purpose |
|---|---|
| [`go-optimizations-101`](skills/go-optimizations-101/SKILL.md) | Practical Go perf playbook (Go 1.19+): allocations, escape analysis, GC pressure, bounds checks, inlining, slice/string/map/channel/interface overhead. Based on Tapir Liu's *Go Optimizations 101*. |

## Install

### Option 1 — Claude Code plugin marketplace

```bash
# Inside Claude Code
/plugin marketplace add pratikbin/skills
/plugin install pratikbin-skills@pratikbin-skills
```

All four skills become available with namespaced commands. Update later with `/plugin marketplace update`.

### Option 2 — `skills.sh` CLI

```bash
# Install all skills
npx skills add pratikbin/skills

# Or install a single skill
npx skills add pratikbin/skills --skill uncloud-deploy

# List before installing
npx skills add pratikbin/skills --list
```

Install globally (`-g`), to a specific agent (`-a claude-code`), or bundle flags for CI (`-y`). See [skills.sh docs](https://skills.sh/docs).

### Option 3 — manual clone

```bash
git clone https://github.com/pratikbin/skills ~/pratikbin-skills
ln -s ~/pratikbin-skills/skills/uncloud-deploy ~/.claude/skills/uncloud-deploy
```

Repeat for each skill you want.

## Repository layout

```
.
├── .claude-plugin/
│   ├── marketplace.json     # Claude Code plugin marketplace catalog
│   └── plugin.json          # Plugin manifest
├── skills/
│   ├── uncloud-cluster/
│   │   ├── SKILL.md
│   │   ├── references/
│   │   └── evals/
│   ├── uncloud-compose/
│   ├── uncloud-deploy/
│   └── uncloud-ops/
├── LICENSE
└── README.md
```

Each skill is self-contained: a `SKILL.md` with frontmatter (`name`, `description`) plus optional `references/` and `evals/` directories. The flat layout is intentional — it satisfies both the Claude Code plugin spec (`skills/<name>/SKILL.md`) and the `skills.sh` CLI discovery algorithm without duplication.

## Contributing

Issues and PRs welcome. If you're adding a new skill:

1. Drop it into `skills/<topic>-<subject>/` with a `SKILL.md`.
2. Frontmatter must include `name` and `description`. Keep `description` specific — it's how Claude decides when to trigger the skill.
3. Keep `SKILL.md` under ~500 lines. Overflow goes into `references/`.
4. Add a row to the table above.

## License

[MIT](LICENSE) © 2026 pratikbin
