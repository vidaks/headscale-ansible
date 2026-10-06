# Contributing

Contributions are welcome. Please open an issue to discuss non-trivial changes before submitting a pull request.

## Guidelines

- All plays must be idempotent. A second apply must report `changed=0`.
- All tasks must support check mode (`--check`).
- Respect defensive defaults: restrictive default values, no DNS or default route side effects, and no restart handlers. Restarts must remain explicit and change-gated.
- Do not commit secrets, private IP addresses, or environment hostnames. Keep local values in gitignored files (`group_vars/`, `inventory.ini`).

## Local Development

Clone the repository and install dependencies:

```bash
git clone https://github.com/vidaks/headscale-ansible && cd headscale-ansible
ansible-galaxy collection install -r requirements.yml
ansible-lint
ansible-playbook site.yml --syntax-check
```

Test on a Fedora host with Podman and Traefik:

```bash
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
ansible-playbook verify.yml
ansible-playbook site.yml
```

The second run must report `changed=0`.

## Code Style

- Use Fully Qualified Collection Names (FQCN) for all modules.
- Scope `become` to individual tasks rather than entire plays.
- Comments must explain rationale rather than obvious mechanics.

## Reporting Bugs and Security Issues

- For bug reports and feature requests, open a GitHub issue using the provided templates.
- For security vulnerabilities, do not open a public issue. Follow the instructions in [SECURITY.md](SECURITY.md).

All contributions are subject to the [MIT License](LICENSE).
