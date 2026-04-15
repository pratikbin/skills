---
name: uncloud-ops
description: Day-2 operations and troubleshooting for running Uncloud services. Use this whenever the user wants to inspect a service, stream or filter logs, exec into a container, scale replicas up or down, stop/start/remove a service, list containers, inspect Caddy's generated config, check the WireGuard mesh, create or inspect volumes, or debug why a service is down, unreachable, or returning 502. Trigger on phrases like "uc logs", "uc ps", "uc exec", "uc inspect", "uc scale", "uc ls", "service is down", "502 bad gateway", "check my uncloud service", "which machine is the service running on", "tail logs", "shell into my container", "uc caddy config", "manage caddy service", "uc dns show", "uc volume".
---

# Uncloud day-2 operations and troubleshooting

This skill is for **operating already-deployed** Uncloud services. If the user is bootstrapping a cluster, go to `uncloud-cluster`. For writing compose files, `uncloud-compose`. For running `uc deploy` / `uc build`, `uncloud-deploy`.

Core everyday commands:

| Command | Purpose |
|---------|---------|
| `uc ls` | List all services |
| `uc ps` | List containers (replicas) per service |
| `uc inspect <service>` | Full state of a service (containers, ports, health, machines) |
| `uc logs <service>` | View / stream logs |
| `uc exec <service>` | Exec into a running container |
| `uc scale <service> <n>` | Change replica count |
| `uc start/stop/rm <service>` | Lifecycle |
| `uc caddy config` | Dump the effective Caddyfile |
| `uc caddy deploy` | Update or redeploy the Caddy ingress service |
| `uc wg show` | WireGuard mesh state |
| `uc dns show / reserve / release` | Managed cluster domain |
| `uc volume ls / inspect / create / rm` | Volumes per machine |
| `uc machine ls` | Cluster membership |
| `uc images` | Images per machine |

## Quick status flow (the first things to run when something's wrong)

```bash
uc ls                         # overview: which services, how many replicas, status
uc ps                         # per-container state: running, health, machine, image, ports
uc inspect web                # full detail for the service in question
uc logs -f web                # tail recent logs
uc machine ls                 # are all machines still reachable?
uc caddy config               # what does Caddy actually serve?
```

If the user says "my service is down", these six commands will almost always point at the cause.

## Listing services and containers

```bash
uc ls                          # one line per service
uc ps                          # one line per container (replica), grouped by service
uc ps web                      # filter to one service
```

`uc ps` shows machine placement, health, image in use, and published ports. Use it to answer:

- "Which machine is this replica on?"
- "Why is one replica unhealthy?"
- "Did the new image actually roll out to all replicas?"

`uc inspect <service>` prints the full state: desired vs actual containers, effective Caddy config for that service, volumes, env vars, pre-deploy hook state, and placement.

## Logs

```bash
uc logs web                                # recent (100 lines per replica)
uc logs -f web                             # follow in real time
uc logs web api db                         # multiple services
uc logs                                    # all services in the current compose file
uc logs -n 20 web                          # last 20 lines per replica
uc logs -n all web                         # no line limit
uc logs -m vps1,vps2 web                   # only replicas on specific machines
uc logs --since 2m30s web                  # relative time
uc logs --since 2025-12-20T10:00:00 web    # absolute time (local)
uc logs --since 1h --until 30m web         # time range
uc logs --utc web                          # timestamps in UTC
```

All time-range flags accept: relative duration, RFC 3339 date/datetime, Unix timestamp.

Pre-deploy hook containers are kept around on failure. View their logs the same way — Uncloud assigns them a stable container name so `uc logs <service>` includes the hook.

## Exec into a container

```bash
uc exec web                                  # interactive shell (tries bash then sh)
uc exec web /bin/zsh                         # explicit shell
uc exec --container abc123 web ls /app       # pick a specific replica by ID or prefix
cat backup.sql | uc exec -T db psql -U postgres mydb    # pipe input (-T for no TTY)
uc exec -d web /scripts/cleanup.sh           # detached / background
```

If a service has multiple replicas and `--container` is not set, `uc exec` attaches to a **random** replica. For deterministic debugging, grab a container ID from `uc ps` first.

## Scaling

```bash
uc scale web 5            # set 'web' to 5 replicas (replicated mode only)
uc scale worker 0         # scale to zero (effectively pause, service still exists)
```

Global-mode services (`deploy.mode: global`) can't be scaled this way — they always have one replica per machine. Add/remove machines with `uc machine add` / `uc machine rm` instead, or edit `x-machines` in the compose file and redeploy.

## Start, stop, remove

```bash
uc stop web               # stop all replicas (containers still exist)
uc start web              # restart them
uc rm web                 # delete the service and its containers
uc rm web api db          # remove multiple
```

Removing a service **does not** delete named volumes. Volume cleanup is manual (`uc volume rm`).

## Debugging 502 / service unreachable

Work from the outside in:

1. **DNS resolves to a cluster machine?**
   ```bash
   dig +short app.example.com
   uc machine ls   # confirm the IPs match
   ```
   If DNS points elsewhere (old CNAME, Cloudflare proxy cached), that's the issue.

2. **Caddy actually has a site for this hostname?**
   ```bash
   uc caddy config | grep -A 5 app.example.com
   ```
   Look for the site block and its upstream list. No block = Caddy does not know about this hostname → check `x-ports` in compose and that the service was deployed.

3. **Upstream IPs healthy?**
   ```bash
   uc ps web
   ```
   Status should be `running` + `healthy`. Unhealthy containers are removed from Caddy automatically.

4. **Service actually listening on the port it claims?**
   ```bash
   uc exec web -- netstat -tlnp        # or: ss -tlnp, lsof -i, curl http://localhost:8000
   ```

5. **Logs**:
   ```bash
   uc logs -n 200 web
   ```

6. **WireGuard mesh healthy** (for cross-machine traffic):
   ```bash
   uc wg show
   ```
   Look for dead peers / handshake issues if replicas live on another machine.

7. **Ambiguous hostname**: `uc caddy config` will show `# Skipped invalid user-defined configs:` with a reason if two services claim the same hostname. Fix by editing one of them.

## Managing Caddy itself

Caddy runs as a normal Uncloud service called `caddy` (deployed globally on every machine by default). Treat it like any other service:

```bash
uc ps caddy              # where is Caddy running
uc logs caddy            # Caddy's own logs
uc caddy config          # the merged Caddyfile it serves
uc caddy deploy          # redeploy Caddy (e.g. new image version)
```

### `uc caddy deploy` flags

| Flag | Purpose |
|------|---------|
| `--image` | Override the Caddy image (default latest `caddy:<version>`) |
| `--caddyfile` | Path to a global custom Caddyfile, prepended to auto-generated config |
| `-m, --machine` | Restrict to specific machines |

### Custom Caddy image (e.g. with Cloudflare DNS plugin)

For wildcard certs via DNS challenge:

```bash
uc caddy deploy --image caddybuilds/caddy-cloudflare:2.10.2 \
  --caddyfile ./global.Caddyfile
```

Or manage the `caddy` service declaratively in `compose.yaml`:

```yaml
services:
  caddy:
    image: caddybuilds/caddy-cloudflare:2.10.2
    command: caddy run -c /config/Caddyfile
    environment:
      CADDY_ADMIN: unix//run/caddy/admin.sock
    env_file:
      - .env.secrets        # CLOUDFLARE_API_TOKEN=xxx
    volumes:
      - /var/lib/uncloud/caddy:/data
      - /var/lib/uncloud/caddy:/config
      - /run/uncloud/caddy:/run/caddy
    x-ports:
      - 80:80@host
      - 443:443@host
      - 443:443/udp@host
    x-caddy: Caddyfile
    deploy:
      mode: global
```

:::warning
Do not change `command`, `environment`, `volumes`, or `x-ports` source paths for the `caddy` service. The Uncloud daemon relies on them to communicate with Caddy.
:::

Then `uc deploy` as usual.

### Verifying Caddy config

```bash
uc caddy config
```

Output includes:

- Global options from user-defined `x-caddy` of the `caddy` service
- Auto-generated sites from all services' `x-ports`
- Custom per-service Caddy snippets from `x-caddy`
- A special `/.uncloud-verify` endpoint for health checks
- Skipped-invalid-config comments listing broken rules with reasons

Look for `# Skipped invalid user-defined configs:` — that's where Caddy tells you which service's `x-caddy` is bad.

## Internal DNS (service-to-service)

Inside the cluster, services reach each other by **service name**:

- `db` → all healthy `db` replicas
- `db.internal` → same (the `.internal` suffix is explicit)
- `<container-id>.db` → a specific replica
- `<machine-id>.db` → only replicas on a specific machine

The resolution mode is **round-robin** by default. Resolution prefers replicas on the **nearest machine** when you use `.nearest` suffixes (see the docs' internal DNS section for exact semantics).

No need to publish ports for cross-service traffic. Publishing is only for things that need to be reachable from outside the cluster.

## DNS management (managed domain)

```bash
uc dns show              # what domain, if any, is reserved
uc dns reserve           # reserve a free xxxxxx.uncld.dev domain
uc dns release           # give it up
```

If a user added a custom domain later, they can `uc dns release` to free the managed one once they confirm their own domain works.

## Volumes

```bash
uc volume ls                             # all volumes, grouped by machine
uc volume inspect <name>                 # details on one volume
uc volume create mydata -m vps1          # create on a specific machine
uc volume create mydata -m vps1 -d local -o type=nfs,device=...
uc volume rm <name>
```

Volumes are **machine-scoped**. A "named volume" used by a service on two machines produces two independent volumes, one per machine. Pin stateful services to a single machine with `x-machines` to avoid this footgun. For true shared storage, use an NFS/CIFS volume driver.

## WireGuard / mesh debugging

```bash
uc wg show
```

Shows the WireGuard interface, peers, last-handshake times, and endpoints on the machine you're connected to. Use it when services on different machines can't reach each other. Common issues:

- **No handshake**: UDP 51820 blocked by firewall or NAT; check `--wg-endpoint` and `--public-ip`
- **Only one peer shown**: the CLI is connected to a specific machine; run it against each machine in turn
- **Wrong endpoint**: machine moved IPs; re-add with `uc machine add --wg-endpoint <new>`

## Machine-level commands

```bash
uc machine ls               # cluster inventory
uc machine rename <old> <new>
uc machine update           # upgrade uncloudd on machines
uc machine rm <name>        # remove from cluster view (does NOT uninstall remotely)
```

For full install/add lifecycle, see `uncloud-cluster`.

## Common gotchas

- **502 Bad Gateway after deploy**: service is unhealthy → Caddy removed it from upstreams. Check `uc ps` for health, then `uc logs` for root cause.
- **"ambiguous site definition"** in `uc caddy config`: two services declared the same hostname. Fix one or add `x-caddy` to disambiguate.
- **`uc logs` shows nothing**: the service might have zero replicas. `uc ls` + `uc ps`. Or the `--since` window missed everything — drop it.
- **`uc exec` lands on a different replica than expected**: pass `--container <id>` from `uc ps`.
- **Volumes disappeared after `uc rm`**: they didn't — `uc rm` only removes the service. Find them with `uc volume ls`.
- **Service unreachable across machines**: check WireGuard first with `uc wg show`. Cross-machine traffic depends on the mesh.
- **Wrong cluster**: `uc ctx ls` and `uc ctx use <name>` to switch. Or use `-c/--context` per command.
- **"nothing happens" scaling a global service**: global mode has one per machine by design; `uc scale` doesn't apply. Adjust `x-machines` or add/remove machines.

## Tips

- For long debug sessions, put `export UNCLOUD_CONTEXT=prod` in the shell so every command targets the right cluster.
- `uc inspect <service>` is your friend. It collapses everything the CLI knows about a service into one output.
- `uc logs -f` combined with a live deploy is the fastest feedback loop.
- Cluster-wide view: `uc machine ls && uc ls && uc ps` is a good health snapshot to dump into a triage thread.

This SKILL.md is the day-2 reference. Most questions are answered above. If you need something more esoteric (exact JSON field in `uc inspect`, specific `uc volume create` driver options), fall through to the online docs at `https://uncloud.run/docs` or the `website/docs/9-cli-reference/` folder in the repo.
