# headscale-ansible

An Ansible project that deploys [Headscale](https://headscale.net/) — a self-hosted,
BSD-3-licensed replacement for the Tailscale coordination server — as a rootful Podman
Quadlet container on Fedora, behind an existing Traefik reverse proxy.

**What Headscale is:** A coordination server (control plane) that distributes WireGuard
public keys between Tailscale clients and enforces ACL policy. It does not run WireGuard
itself; all VPN tunnels are peer-to-peer between the client devices.

**What this project is not:** The server running this playbook does not join the tailnet
as a node. Running Headscale on a machine that is also a tailnet member is unsupported
by the Headscale project.

## Features

- **BSD-3-licensed.** No dual-license, no CLA, no commercial tier.
- **Rootful Podman Quadlet.** Consistent with the existing server stack.
- **Traefik integration.** Sits behind the existing reverse proxy; relies on the
  proxy's wildcard certificate for any subdomain.
- **gRPC-correct.** Traefik uses `h2c://` backend scheme for the TS2021 Noise protocol.
- **No DNS side-effects.** MagicDNS disabled; `/etc/resolv.conf` verified unchanged.
- **No routing side-effects.** Default route snapshotted and verified unchanged.
- **SQLite.** No extra database service; recommended by upstream for new deployments.
- **Public DERP.** Uses Tailscale's public DERP relay network (relay traffic is E2E
  WireGuard-encrypted; Tailscale Inc. cannot read it). Self-hosted DERP is an optional
  future supplement.
- **Auto-approve exit-nodes.** Operator-owned nodes advertising `0.0.0.0/0` / `::/0`
  / the exit-node flag are approved by ACL `autoApprovers` — no manual
  `headscale nodes approve-routes`.
- **Push tailnet DNS.** Pushed nameservers (`1.1.1.1` + `1.0.0.1` by default) reach
  opt-in clients via `--accept-dns=true`, so they get a working resolver regardless of
  the network they're on.
- **Idempotent.** A clean second apply reports zero changes.
- **Standalone verification.** `verify.yml` asserts posture at any time.

## Prerequisites

1. Traefik configured in directory provider mode (watches `dynamic/` rather than a
   single `dynamic.yml`).
2. A DNS record for the headscale domain (e.g. `headscale.example.com`) pointing to
   this server.

## Quick start

### 1. Install dependencies

```bash
ansible-galaxy collection install -r requirements.yml
```

### 2. Create the vault password file

```bash
umask 077
printf '%s' 'your-strong-passphrase' > .vault_pass
chmod 600 .vault_pass
```

### 3. Create the inventory

```bash
cat > inventory.ini <<'EOF'
[headscale_nodes]
<host> ansible_connection=local ansible_host=127.0.0.1 ansible_python_interpreter=/usr/bin/python3
EOF
```

### 4. Create the vars file

```bash
mkdir -p group_vars/all
cat > group_vars/all/vars.yml <<'EOF'
---
headscale_server_url: "https://headscale.example.com"
headscale_domain: "headscale.example.com"
headscale_dns_magic_domain: "ts.example.com"
headscale_host_ip: "192.0.2.10"
headscale_traefik_dynamic_dir: "/path/to/traefik/dynamic"
headscale_admin_user: "admin"
EOF
```

### 5. Create an empty vault (for future secrets)

```bash
ansible-vault create group_vars/all/vault.yml
# Enter passphrase, then type: {}
```

### 6. Apply

```bash
ansible-playbook site.yml --check --diff    # dry run
ansible-playbook site.yml                    # apply
ansible-playbook verify.yml                  # read-only verification
ansible-playbook site.yml                    # must report changed=0
```

## Client onboarding

Headscale issues its own credentials. There is no password and no Tailscale
account. You authorize a device with a pre-auth key — a short-lived token minted
on the server. Run every server command inside the container:
`sudo podman exec headscale headscale ...`.

The server also serves a live setup page per platform at
`https://headscale.example.com/apple` (iOS, iPadOS, macOS, tvOS). The steps below
match it.

### Add a user

A user owns the devices registered under it. List users, or create one:

```bash
sudo podman exec headscale headscale users list
sudo podman exec headscale headscale users create alice --email alice@example.com
```

The username is a positional argument. `--email` and `--display-name` are
optional. Note the numeric ID from `users list`. The pre-auth key command takes
the ID, not the name.

### Generate a pre-auth key

```bash
# single-use key, valid 24h, for user ID 1
sudo podman exec headscale headscale preauthkeys create --user 1 --expiration 24h
```

| Flag | Effect |
|---|---|
| `--user <id>` | Owning user, by numeric ID. Required |
| `--expiration <dur>` | Key lifetime, e.g. `1h`, `24h`. Default `1h`. Bounds key use, not node lifetime |
| `--reusable` | Let more than one device use the key |
| `--ephemeral` | Remove nodes joined with the key when they go offline |
| `--tags <tag,...>` | Assign ACL tags to the node |

The command prints the key (`hskey-auth-…`). It is a secret and expires on its
own. List or revoke keys by ID:

```bash
sudo podman exec headscale headscale preauthkeys list          # all keys, with ID and owner
sudo podman exec headscale headscale preauthkeys expire --id 5 # revoke key ID 5
```

### Connect a device

Set the coordination server on the device, then authorize it with the key.

**iOS and iPadOS** — the same Tailscale app from the App Store:

1. Install and open Tailscale.
2. Tap the account icon (top right) and select **Log in…**.
3. Tap the options menu (top right) and select **Use custom coordination server**.
4. Enter `https://headscale.example.com`.
5. Sign in. Provide the pre-auth key when prompted.

**macOS** — choose one method:

- Command line (`tailscale` from Homebrew):
  ```bash
  tailscale up --login-server https://headscale.example.com --authkey <key>
  tailscale status
  ```
- GUI app: hold **Option (⌥)** and click the Tailscale menu-bar icon. Hover
  **Debug**, open **Custom Login Server**, then **Add Account…**. Enter
  `https://headscale.example.com` and finish the browser sign-in.
- Config profile: download and inspect
  `https://headscale.example.com/apple/macos-app-store` (App Store build) or
  `https://headscale.example.com/apple/macos-standalone` (standalone build).
  Install it under **System Settings → Profiles**. Restart Tailscale and sign in.

Confirm the device on the server:

```bash
sudo podman exec headscale headscale nodes list
```

## Role variables

### Required (no defaults — must be set in `group_vars/all/vars.yml`)

| Variable | Description |
|---|---|
| `headscale_server_url` | Public HTTPS URL of this headscale instance |
| `headscale_domain` | Domain for the Traefik routing rule |
| `headscale_dns_magic_domain` | MagicDNS base domain for tailnet devices |
| `headscale_host_ip` | Host IP that Traefik uses to reach the container |
| `headscale_traefik_dynamic_dir` | Path to Traefik's dynamic config directory on the host |
| `headscale_admin_user` | Headscale username that owns operator-managed nodes; used by ACL auto-approvers and matched by the rekey scripts |

### Defaults (`roles/headscale/defaults/main.yml`)

| Variable | Default | Description |
|---|---|---|
| `headscale_version` | `0.28.0` | Headscale image tag |
| `headscale_image` | `ghcr.io/juanfont/headscale` | Container image |
| `headscale_listen_addr` | `0.0.0.0:8080` | Internal HTTP+gRPC listen address |
| `headscale_metrics_addr` | `127.0.0.1:9091` | Prometheus metrics (internal only) |
| `headscale_config_dir` | `/mnt/config/headscale` | Host-side config directory |
| `headscale_data_dir` | `/mnt/config/headscale/data` | Host-side data directory (SQLite) |
| `headscale_log_level` | `warn` | Log verbosity |
| `headscale_magic_dns` | `false` | MagicDNS disabled (preserves system DNS) |
| `headscale_embedded_derp_enabled` | `false` | Use Tailscale public DERP relays |
| `headscale_dns_global_nameservers` | `[1.1.1.1, 1.0.0.1]` | Resolvers pushed to opt-in clients |
| `headscale_container_uid` / `_gid` | `65532` | Distroless `nonroot` UID/GID — single source of truth |
| `headscale_ui_enabled` | `false` | Deploy optional headscale-ui web panel |

## Verification

`verify.yml` is read-only and can be run at any time:

```bash
ansible-playbook verify.yml
```

Asserts:
1. Headscale container is running.
2. Internal health endpoint (`/health`) responds HTTP 200.
3. External HTTPS endpoint (`headscale_server_url/health`) responds HTTP 200.
4. Traefik routing file is present.
5. Default route is unchanged.
6. `/etc/resolv.conf` checksum is unchanged.

## Trusted-network scope (accepted residual risk)

The mangle PREROUTING rule (`firewall.yml`) drops direct access to
`headscale_host_ip:headscale_host_port` from everything except
`headscale_trusted_network` — by default the whole container bridge
(`10.88.0.0/16`), not just the reverse proxy. Every container on that bridge
can therefore reach headscale's API directly, bypassing the proxy's L7
defenses (CrowdSec, rate limiting).

Reviewed 2026-07-05 and kept, with an external second opinion taken. The
reasoning:

- Only the reverse proxy legitimately dials this port from the bridge, but its
  bridge IP is a dynamic netavark lease that churns across restarts. Pinning a
  static IP and narrowing to a /32 trades a bounded exposure for an
  IPAM-collision failure mode: if another container ever holds the pinned
  address when the proxy restarts, the proxy fails to start and all ingress —
  including this coordination server, the operator's remote-admin path — goes
  down.
- The clean mechanism is a dedicated single-member network for the proxy
  (subnet-as-identity, no pinned address). That is a coordinated change across
  every surface that enumerates the proxy's networks (firewalld trusted
  sources, IP allowlists, watchdog gateway checks, validate assertions) and
  belongs to the co-hosted stack's planned class-wide firewalld
  source-restriction work, not to this repo alone. When it lands: add the new
  subnet to `headscale_trusted_proxy_networks` first (priority-9 RETURN, so
  there is no cutover outage), move the proxy, then flip
  `headscale_trusted_network` to the new subnet.
- The exposure is bounded meanwhile: node authentication is TS2021 (Noise,
  node keys), registration requires an operator-minted high-entropy pre-auth
  key, and the metrics port is loopback-only. What a compromised bridge
  container gains is headscale's unauthenticated HTTP surface (health,
  platform-config and registration endpoints) without L7 filtering — a real
  but narrow CVE/DoS surface, and neighbor DoS is not actually prevented by
  narrowing (co-tenants share the host's kernel and can flood the public route
  through the proxy regardless).

For this deployment the decision is also recorded in the plexarr repo's
`docs/security-residual-risks.md`, next to the other accepted co-tenant risks.

## Rollback

```bash
sudo systemctl stop headscale
sudo systemctl disable headscale
sudo rm /etc/containers/systemd/headscale.container
sudo systemctl daemon-reload
sudo rm <headscale_traefik_dynamic_dir>/headscale.yml
# Traefik hot-reloads and removes the headscale route automatically.
```

## Backup and disaster recovery

Tracked content lives on the private remote (`vidaks/headscale-ansible`, since
2026-07-05; history scrubbed of personal data before first publish — keep real
domains/IPs in `group_vars`, placeholders in tracked files). The gitignored
files are the unrecoverable part: `group_vars/all/vars.yml` (split-DNS
`dns.extra_records`, `magic_dns`, trusted proxy networks), `vault.yml`, and
`inventory.ini` exist only on the host and in the plexarr stack's nightly
gitignored-essentials bundle
(`/mnt/data/backups/system/homelab-gitignored_<ts>.tar.gz`, 0600 root, newest
7 kept). `.vault_pass` is in neither — it lives only in the operator's
password manager.

Restore: clone the private remote into `~/source/git/headscale`, untar the
bundle over it, recreate `.vault_pass` from the password manager. Rebuild
ordering relative to the plexarr stack (its internal-only routes are
tailnet-dead until this repo is applied) is documented in
`plexarr/docs/disaster-recovery.md` §6.

Scope note: this covers the *repo*. Headscale's runtime state (the SQLite DB
holding node registrations, under `/mnt/config/headscale/`) is a separate
concern and is **not** in this bundle or the plexarr services backup — losing
it means every tailnet device re-registers.

## Auth key rotation

```bash
sudo podman exec headscale headscale preauthkeys list             # find the old key ID
sudo podman exec headscale headscale preauthkeys expire --id 5    # revoke it
sudo podman exec headscale headscale preauthkeys create --user 1 --expiration 24h
sudo tailscale login --login-server https://headscale.example.com --authkey <new-key>
```

## Project layout

```
ansible.cfg                              # inventory path, vault_password_file
requirements.yml                         # Galaxy collection dependencies
site.yml                                 # apply playbook
verify.yml                               # read-only verification
roles/headscale/
  defaults/main.yml                      # all tunables with safe defaults
  vars/main.yml                          # internal constants
  tasks/
    main.yml                             # orchestration
    preflight.yml                        # snapshot state, validate inputs
    dirs.yml                             # create config/data directories
    image.yml                            # pull container image
    config.yml                           # render config.yaml
    acl.yml                              # render ACL policy
    quadlet.yml                          # deploy systemd Quadlet unit
    traefik.yml                          # deploy Traefik routing file
    firewall.yml                         # restrict direct port access
    verify.yml                           # post-apply assertions
  handlers/main.yml                      # restart headscale
  meta/main.yml                          # Galaxy metadata
  templates/
    config.yaml.j2                       # headscale config
    acl.hujson.j2                        # default ACL policy
    headscale.container.j2               # Podman Quadlet unit
    headscale-traefik.yml.j2             # Traefik dynamic config
inventory.ini                            # gitignored — environment-specific
group_vars/all/
  vars.yml                               # gitignored — non-secret overrides
  vault.yml                              # gitignored — ansible-vault encrypted secrets
.vault_pass                              # gitignored — vault passphrase
```

## License

MIT.
