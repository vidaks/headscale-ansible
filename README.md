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
- **Traefik integration.** Sits behind the existing reverse proxy; wildcard cert covers
  any `*.example.com` subdomain automatically.
- **gRPC-correct.** Traefik uses `h2c://` backend scheme for the TS2021 Noise protocol.
- **No DNS side-effects.** MagicDNS disabled; `/etc/resolv.conf` verified unchanged.
- **No routing side-effects.** Default route snapshotted and verified unchanged.
- **SQLite.** No extra database service; recommended by upstream for new deployments.
- **Public DERP.** Uses Tailscale's public DERP relay network (relay traffic is E2E
  WireGuard-encrypted; Tailscale Inc. cannot read it). Self-hosted DERP is an optional
  future supplement.
- **Idempotent.** A clean second apply reports zero changes.
- **Standalone verification.** `verify.yml` asserts posture at any time.

## Prerequisites

1. The plexarr `reverse-proxy` role must have been deployed with Traefik in directory
   provider mode (watches `dynamic/` instead of a single `dynamic.yml`).
2. A DNS record for the headscale domain (e.g. `hs.example.com`) pointing to this server.

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
tux ansible_connection=local ansible_host=127.0.0.1 ansible_python_interpreter=/usr/bin/python3
EOF
```

### 4. Create the vars file

```bash
mkdir -p group_vars/all
cat > group_vars/all/vars.yml <<'EOF'
---
headscale_server_url: "https://hs.example.com"
headscale_domain: "hs.example.com"
headscale_dns_magic_domain: "ts.example.com"
headscale_host_ip: "192.0.2.10"
headscale_traefik_dynamic_dir: "/mnt/config/reverse-proxy/traefik/dynamic"
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

Headscale manages its own auth keys — not Tailscale SaaS keys.

```bash
# Create a user
sudo podman exec headscale headscale users create vidar

# Generate a pre-auth key (expires in 1 hour by default)
sudo podman exec headscale headscale preauthkeys create --user vidar --expiration 1h
```

**macOS / Linux:**
```bash
sudo tailscale login --login-server https://hs.example.com --authkey <key>
tailscale status
```

**iOS / iPadOS (Tailscale app):**
Settings → ALTERNATE COORDINATION SERVER URL → `https://hs.example.com`
Then tap "Sign in" and use the pre-auth key when prompted.

## Role variables

### Required (no defaults — must be set in `group_vars/all/vars.yml`)

| Variable | Description |
|---|---|
| `headscale_server_url` | Public HTTPS URL of this headscale instance (e.g. `https://hs.example.com`) |
| `headscale_domain` | Domain for Traefik routing rule (e.g. `hs.example.com`) |
| `headscale_dns_magic_domain` | MagicDNS base domain for tailnet devices (e.g. `ts.example.com`) |
| `headscale_host_ip` | Host IP that Traefik uses to reach the container (e.g. `192.0.2.10`) |
| `headscale_traefik_dynamic_dir` | Path to Traefik's dynamic config directory on the host |

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

## Rollback

```bash
sudo systemctl stop headscale
sudo systemctl disable headscale
sudo rm /etc/containers/systemd/headscale.container
sudo systemctl daemon-reload
sudo rm /mnt/config/reverse-proxy/traefik/dynamic/headscale.yml
# Traefik hot-reloads and removes the headscale route automatically.
```

## Auth key rotation

```bash
sudo podman exec headscale headscale preauthkeys list --user vidar
sudo podman exec headscale headscale preauthkeys expire --user vidar --key <old-key>
sudo podman exec headscale headscale preauthkeys create --user vidar --expiration 1h
sudo tailscale login --login-server https://hs.example.com --authkey <new-key>
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
