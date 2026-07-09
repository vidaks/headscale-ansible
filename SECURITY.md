# Security Policy

## Supported versions

This is a personal project; only the latest `main` is supported. Fixes land there.

## Reporting a vulnerability

Report security issues **privately**, not in a public issue:

- Use GitHub's **[Report a vulnerability](https://github.com/vidaks/headscale-ansible/security/advisories/new)**
  (Security → Advisories), or
- open a minimal public issue asking for a private contact channel — without details.

Expect a best-effort response. There is no bounty.

## Security model & expectations

This role deploys a VPN coordination server. The operator carries real responsibility:

- **Secrets live in `ansible-vault` or gitignored files, never in tracked files.**
  `group_vars/all/vault.yml` is encrypted; `vars.yml`, `inventory.ini`, and
  `.vault_pass` are gitignored. Keep real domains, IPs, and hostnames in the
  gitignored vars — tracked files carry placeholders only.
- **Pre-auth keys are credentials.** `headscale preauthkeys create` prints a
  secret. Use short expirations, revoke unused keys, and never paste one into
  an issue.
- **The container port is firewalled to the container bridge.** The mangle
  PREROUTING rule drops direct LAN access so all traffic goes through the
  reverse proxy. Read "Trusted-network scope" in the README before widening
  `headscale_trusted_network` or adding `headscale_trusted_proxy_networks`.
- **The watchdog and rollback machinery restart services as root.** Both are
  deterministic and bounded, but review `templates/headscale-watchdog.sh.j2`
  before enabling the Traefik-restart rung on a host you did not build.
- **Version bumps replay irreversible DB migrations.** The upgrade script
  auto-applies patch releases only; read release notes and snapshot the DB
  before a minor/major bump.

Reporting a way to reach the headscale API past the firewall rule, extract a
vaulted value, or abuse the watchdog's root-level repair ladder is especially
appreciated.
