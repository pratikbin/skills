---
name: uncloud-cluster
description: Set up, expand, and manage Uncloud clusters. Use this whenever the user wants to install Uncloud on a remote machine, initialize a new cluster, add or remove machines, configure WireGuard endpoints or public IPs, set up SSH access to cluster machines, manage cluster contexts (switch between multiple clusters), reserve a managed DNS domain, or uninstall Uncloud. Trigger on phrases like "install uncloud on my VPS", "set up uncloud", "uc machine init", "add a second server to my cluster", "switch uncloud context", "reserve a cluster domain", or any mention of bootstrapping Uncloud infrastructure.
---

# Uncloud cluster setup and management

Uncloud builds a **decentralised cluster** out of any set of Linux machines (cloud VMs, bare metal, home servers) by connecting them over a WireGuard mesh. There is no control plane. Every machine is equal and the `uc` CLI only needs to reach one of them to manage the whole cluster.

This skill covers:

1. Installing `uc` on the operator's local machine
2. Initializing a new cluster from scratch (`uc machine init`)
3. Adding more machines (`uc machine add`)
4. Reserving a managed domain (`uc dns reserve`)
5. Managing multiple clusters via **contexts**
6. Uninstalling Uncloud from a machine

## When this skill applies

Use this skill the moment the user mentions any of:

- Installing or bootstrapping Uncloud (`uc`, `uncloud`, `uncloudd`)
- Creating, joining, removing, or renaming machines in a cluster
- Switching between clusters (`uc ctx use`, contexts, `current_context`)
- Configuring WireGuard endpoints, public IPs, or network CIDRs for machines
- SSH connection problems when running `uc` commands
- The managed DNS service (`uncld.dev`, `uc dns reserve`)
- Uninstalling Uncloud from a machine

If the user is instead asking "how do I deploy an app", use the `uncloud-deploy` skill. If they want to write a `compose.yaml`, use `uncloud-compose`. If they are debugging a running service, use `uncloud-ops`.

## Prerequisites a user needs

Before doing any cluster work, confirm the user has:

- A **Linux server** (Ubuntu 22.04 or Debian 11+ recommended, AMD64 or ARM64) with a **public IP**
- **SSH access** with a **private key** as either `root` or a user with passwordless `sudo`
- Ports **80, 443, and 51820/udp** reachable (HTTP/HTTPS for Caddy, UDP 51820 for WireGuard)
- Minimum **1 vCPU, 512 MB RAM** (Uncloud itself uses around 150 MB RAM)

Ubuntu/Debian are the only officially tested distros. Flag this if they want to use anything else. **Do not suggest Alpine** — musl causes issues.

## Step 1: Install the `uc` CLI locally

```bash
# One-liner install script (macOS, Linux)
curl -fsS https://get.uncloud.run/install.sh | sh
```

Alternatives:
- **Homebrew** (macOS/Linux): `brew install psviderski/tap/uncloud`
- **Debian/Ubuntu**: an official `.deb` repo exists (see docs `2-getting-started/1-install-cli.md`)
- **Manual**: download `uncloud_<os>_<arch>.tar.gz` from `https://github.com/psviderski/uncloud/releases/latest`, extract, rename to `uc`, and move to `/usr/local/bin`

Verify with:

```bash
uc --version
```

## Step 2: Initialize a new cluster

The first `uc machine init` call does four things at once: installs Docker + `uncloudd` on the remote machine, creates the WireGuard mesh, deploys Caddy as a global service, and reserves a free `*.xxxxxx.uncld.dev` domain.

### Hobbyist default (single VPS, managed domain, fastest path)

```bash
uc machine init root@203.0.113.10
```

This is what 90% of self-hosters should run first. It creates a context called `default`, names the machine automatically, deploys Caddy, and reserves a managed domain so the user can immediately access services at `https://<service>.xxxxxx.uncld.dev`.

### Production / multi-cluster (named context, explicit machine name, custom SSH)

```bash
uc machine init ubuntu@vps1.example.com:2222 \
  -c prod \
  -n vps1 \
  -i ~/.ssh/prod_ed25519
```

Use a named context (`-c prod`) whenever the user has more than one cluster. This keeps staging, prod, and home lab contexts separated in `~/.config/uncloud/config.yaml`.

### When to skip Caddy or managed DNS

If the user already runs a reverse proxy on ports 80/443, or wants to bring their own domain immediately, pass `--no-caddy --no-dns`:

```bash
uc machine init root@203.0.113.10 --no-caddy --no-dns
```

Then deploy Caddy and reserve a domain later with `uc caddy deploy` and `uc dns reserve` (see `uncloud-ops`).

### Important flags

| Flag | Purpose |
|------|---------|
| `-c, --context` | Name of the new context in the local config (default `default`) |
| `-n, --name` | Machine name inside the cluster (random if omitted) |
| `-i, --ssh-key` | SSH private key (default `~/.ssh/id_ed25519`) |
| `--public-ip` | Public IP for ingress. `auto` (default), an explicit IP, or `none` to disable ingress on this machine |
| `--wg-endpoint` | Override WireGuard endpoint(s). Format `IP[:PORT]`. Useful when the machine sits behind NAT and needs a reachable address for the mesh |
| `--network` | Cluster IPv4 CIDR (default `10.210.0.0/16`). Change only if it conflicts with existing networks |
| `--no-caddy` | Skip Caddy deployment |
| `--no-dns` | Skip reserving `*.xxxxxx.uncld.dev` |
| `--no-install` | Assume Docker + `uncloudd` are already installed on the machine |
| `-y, --yes` | Auto-confirm. **Required** for non-interactive runs like CI |
| `--version` | Pin a specific `uncloudd` version instead of `latest` |

:::warning
Do **not** pass `--connect` to `uc machine init`. `--connect` is for targeting an existing cluster. `uc machine init` creates a new one and writes a new context to the config file.
:::

## Step 3: Add more machines

Run from the same local workstation (or from any machine with `uc` and access to the cluster config):

```bash
uc machine add root@203.0.113.11 -n vps2
```

Options mirror `machine init` (`-i`, `--public-ip`, `--wg-endpoint`, `--no-caddy`, `--no-install`, `-y`). There is no `-c/--context` flag. The new machine joins the **current** context, so switch contexts with `uc ctx use <name>` first if adding to a non-default cluster.

After adding, verify the cluster:

```bash
uc machine ls
```

Machines with `--no-caddy` will not run the reverse proxy. Use this for dedicated worker or database hosts that should not accept public HTTP traffic.

## Step 4: Reserve a managed domain (optional)

If `--no-dns` was used earlier (or the user wants a second cluster domain), reserve one:

```bash
uc dns reserve
```

This gives the cluster a free `<random>.uncld.dev` zone. Services published without a hostname then get `https://<service-name>.<random>.uncld.dev` automatically. To release it later: `uc dns release`. To show the current one: `uc dns show`.

Point the user to their own domain next. They need to add a `CNAME` or `A` record pointing `example.com` (and/or `*.example.com`) at the cluster machines. Then in their compose file they use `x-ports: ["example.com:8080/https"]` (covered in `uncloud-compose`).

## Step 5: Managing contexts

The config file at `~/.config/uncloud/config.yaml` holds:

- `current_context`: the cluster commands hit by default
- `contexts`: a map of named clusters, each with an ordered list of connections (SSH to different machines)

Useful commands:

```bash
uc ctx ls                       # list all contexts
uc ctx use prod                 # switch current context
uc ctx connection --help        # inspect/edit connection list for a context
```

Two developers on the same team can have **different** local contexts pointing at the **same** cluster. Context is just a local view, not cluster state.

### Running against a cluster without a config file

For CI, scripts, or ad-hoc diagnosis:

```bash
# Use system ssh (full ~/.ssh/config support)
uc --connect root@203.0.113.10 ls

# Same cluster, Go's built-in SSH library (when system ssh is unavailable)
uc --connect ssh+go://root@203.0.113.10 ls

# Direct gRPC over Unix socket when you are on the machine itself
uc --connect unix:///run/uncloud/uncloud.sock ls
```

`--connect` and `UNCLOUD_CONNECT` override the config entirely. `--context` / `UNCLOUD_CONTEXT` pick a specific context from the config. Precedence is `--connect` > `--context` > `current_context`.

Override the config path itself with `--uncloud-config` or `UNCLOUD_CONFIG`:

```bash
uc --uncloud-config ./my-config.yaml ls
export UNCLOUD_CONFIG=~/work-uncloud.yaml
```

## Step 6: Uninstall

To remove a service from the cluster, use `uc rm` (see `uncloud-ops`). To wipe Uncloud off a machine entirely, SSH in and run:

```bash
sudo /usr/local/bin/uncloud-uninstall
```

This stops `uncloud.service` and `uncloud-corrosion.service`, removes the binaries, the systemd unit, the `/var/lib/uncloud` state directory, and the `uncloud` system user. **It does not touch Docker or user data volumes.** Warn the user to back up named volumes first if they care about them.

After uninstall, delete the machine from the cluster's local view with `uc machine rm <name>` and remove the context with a manual edit to `~/.config/uncloud/config.yaml` (or delete the whole context entry if the cluster no longer exists).

## Common gotchas

- **SSH fails on `machine init`**: confirm the user can `ssh root@host` manually first. `uc` shells out to system `ssh` by default. If passwordless `sudo` is not configured, use `root`.
- **Port 80/443 already in use**: another web server is running. Either stop it or use `--no-caddy` and run Uncloud behind an existing reverse proxy.
- **NAT / no public IP detected**: pass `--public-ip <ip>` and `--wg-endpoint <ip>:51820` explicitly.
- **Machines behind CGNAT**: need a public WireGuard-reachable relay. This is a non-trivial setup. Flag it, do not pretend it works out of the box.
- **Network CIDR collision**: if the machine's LAN uses `10.210.0.0/16`, pass `--network 10.220.0.0/16` on `machine init` to avoid conflicts.
- **Alpine Linux**: unsupported. The user's global CLAUDE.md also forbids it. Use Ubuntu/Debian.

## References in this skill

- `references/commands.md` — full `uc machine`, `uc ctx`, `uc dns` flag reference with examples
- `references/config-file.md` — `~/.config/uncloud/config.yaml` structure

Read these only when you need details that are not already covered above. For everyday questions, the main body of this SKILL.md is enough.
