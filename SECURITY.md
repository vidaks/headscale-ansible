# Security Policy

## Supported Versions

Only the latest commit on branch `main` receives security updates.

## Reporting a Vulnerability

Report security vulnerabilities privately rather than in public issues:

- Open a private report through GitHub [Security Advisories](https://github.com/vidaks/headscale-ansible/security/advisories/new).
- If that channel is unavailable, open an issue requesting private contact instructions without including vulnerability details.

## Security Architecture

This role deploys a Tailscale coordination server and controls access to its backend.

- Credential Protection: Pre-authenticated keys and tokens are credentials. Assign short expirations, revoke unused keys, and never share keys in issues or logs. Keep secrets encrypted in `group_vars/all/vault.yml`.
- Git Hygiene: Keep sensitive hostnames, domain names, IP addresses, and vault passwords in gitignored files (`group_vars/`, `inventory.ini`, `.vault_pass`). Tracked repository files contain placeholders only.
- Network Isolation: The container port is firewalled via nftables mangle PREROUTING rules. Direct access from external networks is dropped before DNAT, requiring all external client traffic to enter via the reverse proxy.
- Privileged Operations: The self-healing watchdog and rollback mechanisms perform container restarts. Review watchdog scripts and configuration options before enabling optional restart stages.
- Migration Safeguards: Database migrations run forward-only. Create database backups before applying minor or major updates.
