# headscale-ansible

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/vidaks/headscale-ansible/actions/workflows/ci.yml/badge.svg)](https://github.com/vidaks/headscale-ansible/actions/workflows/ci.yml)
[![ansible-core](https://img.shields.io/badge/ansible--core-2.15%2B-blue.svg)](https://docs.ansible.com/)

This Ansible role deploys [Headscale](https://headscale.net/) as a rootful Podman Quadlet on Fedora Server behind a Traefik reverse proxy. Headscale provides an open-source coordination server for Tailscale clients. It manages WireGuard public keys and network policies while client VPN tunnels remain direct and peer-to-peer.

The host executing this role acts as the control plane only. It does not join the tailnet as a client device.

## Features

- **Hardened Podman Quadlet**: Runs containerized with `ReadOnly`, `DropCapability=all`, `NoNewPrivileges`, non-root execution (UID 65532), and memory limits.
- **Traefik Integration**: Generates dynamic routing configuration using the `h2c://` scheme to preserve gRPC protocol traffic across the proxy.
- **Health-Gated Deploys**: Snapshots the SQLite database before version updates and tests health endpoints after restarts. Reverts automatically to the previous image if health checks fail.
- **Self-Healing Watchdog**: Runs a local systemd timer to verify external availability and execute recovery steps without manual intervention.
- **Firewall Isolation**: Enforces mangle PREROUTING rules in nftables to drop direct traffic from outside the container network, keeping the backend behind the proxy.
- **Routing Stability**: Snapshots default routing tables and `/etc/resolv.conf` before execution and validates them after apply.
- **Safe Upgrades**: Includes an upgrade helper script that reports new releases and automates patch updates safely.
- **Idempotency**: Guarantees zero changes on repeated playbook runs.

## Prerequisites

- Fedora Server with Podman and firewalld.
- Traefik configured to watch a dynamic configuration directory, with valid TLS certificates for your domain.
- A public or private DNS record pointing your Headscale domain to the host.

## Quick Start

### 1. Install dependencies

```bash
ansible-galaxy collection install -r requirements.yml
```

### 2. Configure vault password

```bash
umask 077
printf '%s' 'your-vault-passphrase' > .vault_pass
chmod 600 .vault_pass
```

### 3. Define inventory

Create `inventory.ini`:

```ini
[headscale_nodes]
server.example.com ansible_connection=local ansible_host=127.0.0.1 ansible_python_interpreter=/usr/bin/python3
```

### 4. Configure variables

Create `group_vars/all/vars.yml`:

```yaml
---
headscale_server_url: "https://headscale.example.com"
headscale_domain: "headscale.example.com"
headscale_dns_magic_domain: "ts.example.com"
headscale_host_ip: "192.0.2.10"
headscale_traefik_dynamic_dir: "/path/to/traefik/dynamic"
headscale_admin_user: "admin"
```

All inventory files, variables, and vault credentials remain gitignored to keep sensitive network details out of version control.

### 5. Create empty vault file

```bash
ansible-vault create group_vars/all/vault.yml
```

### 6. Run playbook

```bash
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
ansible-playbook verify.yml
ansible-playbook site.yml
```

The second run must report `changed=0`.

## Client Onboarding

Headscale generates its own device credentials using pre-authenticated keys. All server administrative commands execute inside the container:

```bash
sudo podman exec headscale headscale <command>
```

### Add a user

Create a user account to manage devices:

```bash
sudo podman exec headscale headscale users list
sudo podman exec headscale headscale users create alice --email alice@example.com
```

Note the numeric user ID returned by `users list`. Key generation commands use this ID.

### Generate a pre-auth key

Generate a single-use authentication key valid for 24 hours:

```bash
sudo podman exec headscale headscale preauthkeys create --user 1 --expiration 24h
```

| Option | Description |
|---|---|
| `--user <id>` | Numeric ID of the owning user. |
| `--expiration <dur>` | Duration before key expires (for example `1h`, `24h`). |
| `--reusable` | Permits multiple devices to authenticate with the same key. |
| `--ephemeral` | Discards nodes automatically when they disconnect. |
| `--tags <tag,...>` | Assigns ACL tags to the node. |

List or expire keys:

```bash
sudo podman exec headscale headscale preauthkeys list
sudo podman exec headscale headscale preauthkeys expire --id 5
```

### Connect a client device

Configure client software to use your self-hosted server:

- **Linux**:
  ```bash
  sudo tailscale up --login-server https://headscale.example.com --authkey <key>
  ```
- **macOS (CLI)**:
  ```bash
  tailscale up --login-server https://headscale.example.com --authkey <key>
  ```
- **iOS / iPadOS**:
  1. Open the Tailscale app.
  2. Tap the user icon, then select **Log in…**.
  3. Select **Use custom coordination server** from the menu.
  4. Enter `https://headscale.example.com`.
  5. Enter the pre-auth key when prompted.

Verify registered nodes on the server:

```bash
sudo podman exec headscale headscale nodes list
```

## Role Variables

Authoritative defaults and descriptions are documented in [defaults/main.yml](roles/headscale/defaults/main.yml).

### Required Variables

| Variable | Description |
|---|---|
| `headscale_server_url` | Public HTTPS URL for this Headscale instance. |
| `headscale_domain` | Hostname used in Traefik routing rules. |
| `headscale_dns_magic_domain` | MagicDNS search domain for tailnet peers. |
| `headscale_host_ip` | Host IPv4 address used by Traefik to reach the container. |
| `headscale_traefik_dynamic_dir` | Directory path where Traefik reads dynamic routing files. |
| `headscale_admin_user` | Username owning operator nodes, used in ACL auto-approvers. |

### Common Options

| Variable | Default | Description |
|---|---|---|
| `headscale_version` | `0.29.3` | Container image tag. |
| `headscale_image` | `ghcr.io/juanfont/headscale` | Container image repository. |
| `headscale_host_port` | `8080` | Port published on `headscale_host_ip`. |
| `headscale_metrics_host_port` | `9091` | Prometheus metrics port bound to `127.0.0.1`. |
| `headscale_config_dir` | `/mnt/config/headscale` | Host path for configuration files. |
| `headscale_data_dir` | `/mnt/config/headscale/data` | Host path for SQLite database storage. |
| `headscale_magic_dns` | `false` | Enables MagicDNS support. |
| `headscale_dns_global_nameservers` | `[1.1.1.1, 1.0.0.1]` | Upstream DNS resolvers pushed to clients. |
| `headscale_dns_extra_records` | `[]` | Extra DNS records served to tailnet devices. |
| `headscale_trusted_network` | `10.88.0.0/16` | Subnet permitted to access the backend port directly. |
| `headscale_trusted_proxy_networks` | `[]` | Additional subnets permitted for multi-homed proxy setups. |
| `headscale_watchdog_enabled` | `true` | Installs and activates the reachability watchdog timer. |
| `headscale_container_uid` | `65532` | UID used for container execution and file permissions. |

## Deploys and Rollback

Playbook execution manages service updates safely:

1. Captures the active container image identifier before making changes.
2. Creates an online SQLite database backup before pulling new image versions.
3. Renders updated configuration and restarts the container unit.
4. Executes internal and external health checks.
5. If health checks fail, the rescue block restores the previous image tag, restarts the service, and reports the error.

## Self-Healing Watchdog

The `headscale-watchdog.timer` unit triggers every 2 minutes to verify external service reachability.

The script runs locally and depends on no external services. If the endpoint becomes unreachable, the watchdog classifies the failure:

- Host connectivity issues and TLS certificate errors are reported without restarting containers, avoiding loops caused by network link loss.
- Container routing or bridge failures trigger sequential recovery steps: reloading container firewall rules, optionally restarting the proxy, and restarting Headscale.
- Bounded retry limits prevent flapping by limiting repair attempts to 3 times per hour.

## Trusted Network Scope

The nftables mangle PREROUTING rule in `firewall.yml` drops traffic directed to `headscale_host_ip:headscale_host_port` from outside `headscale_trusted_network`.

By default, `headscale_trusted_network` permits the container bridge subnet (`10.88.0.0/16`). Netavark assigns dynamic IP addresses to containers on restart. Allowing the bridge subnet prevents startup failures caused by IP address changes, while completely blocking direct access from external LAN and WAN clients.

## Upgrades

Check for updates or apply patch releases:

```bash
scripts/headscale-upgrade.sh           # Check available versions
scripts/headscale-upgrade.sh --apply   # Apply verified patch updates
```

Because Headscale database migrations are forward-only, minor and major updates require manual verification. Review upstream release notes, create a database snapshot, update `headscale_version`, and run the deployment loop.

## Verification

Run read-only verification checks at any time:

```bash
ansible-playbook verify.yml
```

The playbook validates that:
- The Headscale container is active.
- Internal `/health` returns HTTP 200.
- External `headscale_server_url/health` returns HTTP 200.
- Traefik dynamic routing files exist.
- System routing tables and `/etc/resolv.conf` remain unmodified.

## Removal

To remove Headscale:

```bash
sudo systemctl disable --now headscale-watchdog.timer
sudo rm /etc/systemd/system/headscale-watchdog.{service,timer} /usr/local/bin/headscale-watchdog.sh
sudo systemctl stop headscale
sudo systemctl disable headscale
sudo rm /etc/containers/systemd/headscale.container
sudo systemctl daemon-reload
sudo rm <headscale_traefik_dynamic_dir>/headscale.yml
```

Configuration files and database state in `/mnt/config/headscale` remain on disk until deleted manually.

## Contributing

Contributions and issue reports are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for details. Report security vulnerabilities according to [SECURITY.md](SECURITY.md).

## License

This project is licensed under the [MIT License](LICENSE).
