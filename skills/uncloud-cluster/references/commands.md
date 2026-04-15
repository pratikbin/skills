# Uncloud cluster command reference

## `uc machine init`

Initialize a new cluster by provisioning the first machine.

```
uc machine init [schema://]USER@HOST[:PORT] [flags]
```

### Connection schemes

| Prefix | Meaning |
|--------|---------|
| `ssh://` (or none) | Use system `ssh` binary. Full `~/.ssh/config` support |
| `ssh+go://` | Go's built-in SSH library. No ssh_config support but works when system ssh is unavailable |

### All flags

| Flag | Default | Description |
|------|---------|-------------|
| `-c, --context` | `default` | Local context name for this cluster |
| `-n, --name` | auto | Machine name inside the cluster |
| `-i, --ssh-key` | `~/.ssh/id_ed25519` | SSH private key path |
| `--public-ip` | `auto` | Public IP for ingress. `auto`, explicit IP, or `none` to disable ingress on this machine |
| `--wg-endpoint` | auto | WireGuard endpoint(s). `IP`, `IP:PORT`, `[IPv6]:PORT`. Repeatable or comma-separated |
| `--network` | `10.210.0.0/16` | IPv4 CIDR for the cluster overlay |
| `--no-caddy` | false | Skip Caddy deployment |
| `--no-dns` | false | Skip reserving the managed `*.uncld.dev` domain |
| `--no-install` | false | Assume Docker + `uncloudd` are already installed |
| `--version` | `latest` | `uncloudd` version to install |
| `--dns-endpoint` | `https://dns.uncloud.run/v1` | Override Uncloud DNS API |
| `-y, --yes` | false | Auto-confirm. Required for non-interactive runs |

### Examples

```bash
# Minimal hobbyist setup
uc machine init root@203.0.113.10

# Named context + machine name
uc machine init root@vps1.example.com -c prod -n vps1

# Non-root SSH user, custom port, custom key
uc machine init ubuntu@vps1.example.com:2222 -i ~/.ssh/mykey

# No Caddy, no managed DNS (you bring your own reverse proxy)
uc machine init root@vps1 --no-caddy --no-dns

# Explicit public IP and WG endpoint (machine behind NAT, port forwarded)
uc machine init root@203.0.113.10 \
  --public-ip 203.0.113.10 \
  --wg-endpoint 203.0.113.10:51820
```

## `uc machine add`

Add another machine to the **current** cluster context.

```
uc machine add [schema://]USER@HOST[:PORT] [flags]
```

Flags are a strict subset of `machine init`:

- `-n, --name`
- `-i, --ssh-key`
- `--public-ip`
- `--wg-endpoint`
- `--no-caddy`
- `--no-install`
- `--version`
- `-y, --yes`

There is **no** `-c/--context` flag. Switch with `uc ctx use <name>` first if needed.

## `uc machine ls`

List all machines in the current cluster. No flags.

## `uc machine rm <name>`

Remove a machine from the cluster's view. Does not uninstall `uncloudd` from the remote host. Run `uncloud-uninstall` there separately.

## `uc machine rename <old> <new>`

Rename a machine.

## `uc machine update`

Update `uncloudd` on one or more machines to the latest (or a pinned) version.

## `uc ctx ls`

List contexts in the local config.

## `uc ctx use <name>`

Switch `current_context` in `~/.config/uncloud/config.yaml` to `<name>`.

## `uc ctx connection`

Inspect or modify the ordered list of connections inside a context. Connections are tried in order until one succeeds.

## `uc dns reserve`

Reserve a free `<random>.uncld.dev` cluster domain. The cluster must be able to reach `dns.uncloud.run`.

## `uc dns show`

Print the currently reserved cluster domain.

## `uc dns release`

Release the reserved cluster domain. Services that relied on `*.<cluster-domain>` hostnames stop resolving.

## `uc wg show`

Dump the WireGuard interface and peer state on the machine the CLI is currently connected to. Useful for debugging mesh connectivity.

## Global flags (inherited by every command)

| Flag | Env var | Description |
|------|---------|-------------|
| `--connect` | `UNCLOUD_CONNECT` | Connect directly to a machine without using the config. Formats: `[ssh://]user@host[:port]`, `ssh+go://...`, `tcp://host:port`, `unix:///path/to/uncloud.sock` |
| `-c, --context` | `UNCLOUD_CONTEXT` | Pick a context from the config |
| `--uncloud-config` | `UNCLOUD_CONFIG` | Path to the config file (default `~/.config/uncloud/config.yaml`) |

Precedence: `--connect` > `--context` > `current_context`.
