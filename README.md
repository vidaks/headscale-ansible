# headscale-ansible

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/vidaks/headscale-ansible/actions/workflows/ci.yml/badge.svg)](https://github.com/vidaks/headscale-ansible/actions/workflows/ci.yml)
[![ansible-core](https://img.shields.io/badge/ansible--core-2.15%2B-blue.svg)](https://docs.ansible.com/)

**An Ansible role that deploys [Headscale](https://headscale.net/) — a self-hosted,
BSD-3-licensed replacement for the Tailscale coordination server — as a hardened
rootful Podman Quadlet on Fedora, behind an existing Traefik reverse proxy.**
Deploys are health-gated with automatic rollback to the last known-good image, and a
deterministic on-host watchdog repairs reachability faults without operator access.

**What Headscale is:** A coordination server (control plane) that distributes WireGuard
public keys between Tailscale clients and enforces ACL policy. It does not run WireGuard
itself; all VPN tunnels are peer-to-peer between the client devices.

**What this project is not:** The server running this playbook does not join the tailnet
as a node. Running Headscale on a machine that is also a tailnet member is unsupported
by the Headscale project.

## Features

- **Rootful Podman Quadlet**, hardened: `ReadOnly`, `DropCapability=all`,
  `NoNewPrivileges`, distroless non-root UID, 256 MB memory cap, container-level
  health check.
- **Traefik integration.** Drops a dynamic-config file into the proxy's watched
  directory; Traefik hot-reloads it. Uses the `h2c://` backend scheme so the TS2021
  Noise protocol (gRPC) survives the proxy hop.
- **Health-gated deploys with automatic rollback.** Every apply captures the running
  image as a rollback anchor, snapshots the SQLite DB before an image change, and
  verifies internal + external `/health` after restart. A failed verify re-pins the
  prior image and re-verifies — a bad version bump does not leave the server down.
- **Self-healing watchdog.** A 2-minute systemd timer probes external reachability
  and walks a bounded, deterministic repair ladder (netavark rule reload → optional
  proxy restart → service restart) with anti-thrash backoff and deduplicated alerts.
  Built for the remote-lockout case: when SSH is tailnet-only, only an on-host actor
  can fix the tailnet's control plane.
- **Firewalled backend port.** A mangle PREROUTING rule drops direct access from
  outside the container bridge, so LAN clients cannot bypass the proxy's TLS, auth,
  and rate limiting. Stale exceptions are reconciled away on every apply.
- **No DNS or routing side-effects.** The default route and `/etc/resolv.conf` are
  snapshotted pre-apply and asserted unchanged post-apply. MagicDNS is off by
  default; enabling it affects only peers that accept pushed DNS.
- **Split-DNS extra records** (optional). Serve internal-only hostnames to tailnet
  peers so they reach the reverse proxy through the tunnel while the WAN path is
  denied.
- **Exit-node auto-approval.** ACL `autoApprovers` accept routes and exit-node
  advertisements from the operator's own account — no manual approval step after
  every re-auth.
- **Guarded upgrades.** `scripts/headscale-upgrade.sh` reports available releases;
  `--apply` deploys patch bumps only, gated on verification, and rolls the pin back
  on failure. Minor/major bumps are surfaced for manual review because Headscale's
  DB migrations are forward-only.
- **Idempotent.** A clean second apply reports zero changes.
- **Standalone verification.** `verify.yml` asserts posture at any time, read-only.

## Prerequisites

1. Fedora with rootful Podman and firewalld.
2. Traefik configured in directory provider mode (watches a `dynamic/` directory
   rather than a single file), with a certificate covering the headscale domain.
3. A DNS record for the headscale domain (e.g. `headscale.example.com`) pointing to
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

`inventory.ini` and everything under `group_vars/` are gitignored. Real domains,
IPs, and hostnames live only there — tracked files carry placeholders.

### 5. Create an empty vault (for future secrets)

```bash
ansible-vault create group_vars/all/vault.yml
# Enter passphrase, then type: {}
```

### 6. Apply

```bash
ansible-playbook site.yml --check --diff    # dry run
ansible-playbook site.yml                   # apply
ansible-playbook verify.yml                 # read-only verification
ansible-playbook site.yml                   # must report changed=0
```

The four-step loop is the deploy discipline. The `changed=0` re-apply is a contract:
several tasks are deliberately gated to keep it true, so a non-zero second run means
something is wrong.

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

`roles/headscale/defaults/main.yml` is the authoritative, fully commented list.
The tables below cover the ones most deployments touch.

### Required (no defaults — set in `group_vars/all/vars.yml`)

| Variable | Description |
|---|---|
| `headscale_server_url` | Public HTTPS URL of this headscale instance |
| `headscale_domain` | Domain for the Traefik routing rule |
| `headscale_dns_magic_domain` | MagicDNS base domain for tailnet devices |
| `headscale_host_ip` | Host IP that Traefik uses to reach the container (IPv4 — preflight asserts) |
| `headscale_traefik_dynamic_dir` | Path to Traefik's dynamic config directory on the host |
| `headscale_admin_user` | Headscale username that owns operator-managed nodes; used by ACL auto-approvers |

### Common tunables

| Variable | Default | Description |
|---|---|---|
| `headscale_version` | `0.29.2` | Headscale image tag. Patch bumps are safe; minor/major bumps run irreversible DB migrations — read the release notes first |
| `headscale_image` | `ghcr.io/juanfont/headscale` | Container image |
| `headscale_host_port` | `8080` | Host port the container publishes on `headscale_host_ip` |
| `headscale_metrics_host_port` | `9091` | Prometheus metrics, published on 127.0.0.1 only (9090 is Cockpit's) |
| `headscale_config_dir` | `/mnt/config/headscale` | Host-side config directory |
| `headscale_data_dir` | `/mnt/config/headscale/data` | Host-side data directory (SQLite) |
| `headscale_magic_dns` | `false` | MagicDNS. Required for `headscale_dns_extra_records` to be served |
| `headscale_dns_global_nameservers` | `[1.1.1.1, 1.0.0.1]` | Resolvers pushed to clients that accept DNS |
| `headscale_dns_extra_records` | `[]` | Split-DNS records served to tailnet peers (`{name, value, type?}`) |
| `headscale_trusted_network` | `10.88.0.0/16` | Source network allowed to reach the backend port directly (the container bridge) |
| `headscale_trusted_proxy_networks` | `[]` | Extra source networks allowed past the firewall DROP (multi-homed proxy setups) |
| `headscale_watchdog_enabled` | `true` | Deploy and start the self-healing watchdog timer |
| `headscale_watchdog_traefik_restart_enabled` | `false` | Watchdog may restart Traefik. Enable only if Traefik's plugins are local (vendored) |
| `headscale_watchdog_notify_bin` | `""` | Optional push-notification helper for watchdog alerts. Empty = journal + email only |
| `headscale_container_uid` / `_gid` | `65532` | Distroless `nonroot` UID/GID — single source of truth for dirs, files, and the Quadlet `User=` |

## Health-gated deploys and rollback

`site.yml` treats a restart as a transaction:

1. Before anything changes, the currently running image reference is captured
   verbatim as the rollback anchor.
2. If the container image is about to change, the SQLite DB gets a consistent
   `.backup` snapshot while the old version is still running.
3. The restart is an explicit, change-gated task — not a handler. A handler that
   fails during `flush_handlers` aborts the play without triggering `rescue`;
   an explicit task failure does (verified by fault injection).
4. Verification probes the container, the local `/health`, and the external
   HTTPS `/health` (with retries — Quadlet start completes before app-ready).
5. On any failure, the `rescue` re-pins the Quadlet to the prior image, restarts,
   re-verifies, and then fails loudly with the outcome — including the DB-restore
   procedure if the rollback itself cannot read a forward-migrated database.

A deploy sentinel is held for the duration so the watchdog defers instead of
racing the deploy.

## Self-healing watchdog

`headscale-watchdog.timer` fires every 2 minutes and runs a deterministic
classifier + repair ladder. No network dependencies, no API calls — it exists
precisely for when the network is broken.

- **Classify first.** TLS failures alert and stop (a restart cannot fix a cert).
  Transport failures with a healthy proxy and a locally serving entrypoint are
  filed as WAN outages — alert only, nothing restarted.
- **Repair ladder**: reload the two containers' netavark firewall rules (the
  firewalld-reload footgun), optionally restart Traefik (off by default), then
  restart headscale. Each rung re-probes; the ladder stops at first recovery.
- **Anti-thrash**: at most 3 repairs per rolling hour, then one attempt per
  15 minutes. Repeated outage alerts are deduplicated per class; recovery alerts
  always push.
- **Deploy-aware**: stands down whenever the deploy sentinel is fresh.

Alerts go to the journal always, and to email / an optional push helper
(`headscale_watchdog_notify_bin`) when configured.

## Upgrades

```bash
scripts/headscale-upgrade.sh           # report available releases, change nothing
scripts/headscale-upgrade.sh --apply   # deploy patch bumps, verify, roll back on failure
```

Headscale is pre-1.0: DB migrations run automatically on container start, are
forward-only, and break across minor versions. The script therefore auto-applies
patch releases only. A new minor/major is reported with a link to the release
notes and the manual procedure (snapshot the DB, read the notes, bump
`headscale_version`, run the four-step loop).

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

Route/DNS drift detection needs the preflight snapshot, so it only engages on a
full `site.yml` run; standalone `verify.yml` asserts current validity.

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
  sources, IP allowlists, watchdog gateway checks) and belongs to the
  co-hosted stack's own firewalld work, not to this repo alone. When it lands:
  add the new subnet to `headscale_trusted_proxy_networks` first (priority-9
  RETURN, so there is no cutover outage), move the proxy, then flip
  `headscale_trusted_network` to the new subnet.
- The exposure is bounded meanwhile: node authentication is TS2021 (Noise,
  node keys), registration requires an operator-minted high-entropy pre-auth
  key, and the metrics port is loopback-only. What a compromised bridge
  container gains is headscale's unauthenticated HTTP surface (health,
  platform-config and registration endpoints) without L7 filtering — a real
  but narrow CVE/DoS surface, and neighbor DoS is not actually prevented by
  narrowing (co-tenants share the host's kernel and can flood the public route
  through the proxy regardless).

## Removal

```bash
sudo systemctl disable --now headscale-watchdog.timer
sudo rm /etc/systemd/system/headscale-watchdog.{service,timer} /usr/local/bin/headscale-watchdog.sh
sudo systemctl stop headscale
sudo systemctl disable headscale
sudo rm /etc/containers/systemd/headscale.container
sudo systemctl daemon-reload
sudo rm <headscale_traefik_dynamic_dir>/headscale.yml
# Traefik hot-reloads and removes the headscale route automatically.
```

The firewall mangle rules and `/mnt/config/headscale` (including the node
database) stay until removed explicitly.

## State and backups

The tracked repo is reproducible; two things are not:

- **The gitignored files** — `group_vars/all/{vars,vault}.yml`, `inventory.ini`,
  `.vault_pass`. Back them up outside git. Keep `.vault_pass` only in a password
  manager; a backup bundle that contains both the vault and its password defeats
  the encryption.
- **Headscale's runtime state** — the SQLite DB under `headscale_data_dir` holds
  every node registration. Losing it means every device re-registers with a new
  pre-auth key. Snapshot it with `sqlite3 <db> ".backup <dest>"` (the deploy and
  upgrade paths already do this before image changes); a plain file copy of a
  live SQLite DB is not consistent.

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
scripts/
  headscale-upgrade.sh                   # guarded release upgrades (report / --apply)
roles/headscale/
  defaults/main.yml                      # all tunables, fully commented — the reference
  vars/main.yml                          # internal constants
  tasks/
    main.yml                             # orchestration + restart/verify/rollback block
    preflight.yml                        # validate inputs, snapshot route + resolv.conf
    dirs.yml                             # create config/data directories
    image.yml                            # pull container image
    config.yml                           # render config.yaml
    acl.yml                              # render ACL policy
    quadlet.yml                          # render systemd Quadlet unit
    traefik.yml                          # deploy Traefik routing file
    firewall.yml                         # restrict + reconcile direct port access
    watchdog.yml                         # install self-healing watchdog
    verify.yml                           # post-apply assertions
  handlers/main.yml                      # intentionally empty — documents why
  meta/main.yml                          # Galaxy metadata
  templates/
    config.yaml.j2                       # headscale config
    acl.hujson.j2                        # ACL policy with exit-node auto-approval
    headscale.container.j2               # hardened Podman Quadlet unit
    headscale-traefik.yml.j2             # Traefik dynamic config (h2c backend)
    headscale-watchdog.sh.j2             # watchdog classifier + repair ladder
    headscale-watchdog.service.j2        # watchdog oneshot unit
    headscale-watchdog.timer.j2          # 2-minute timer
inventory.ini                            # gitignored — environment-specific
group_vars/all/
  vars.yml                               # gitignored — non-secret overrides
  vault.yml                              # gitignored — ansible-vault encrypted secrets
.vault_pass                              # gitignored — vault passphrase
```

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). This is a personal project maintained on a
best-effort basis. Security reports: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE).
