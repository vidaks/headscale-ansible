# Contributing

Thanks for your interest. This is a small, personal project maintained on a
**best-effort** basis — issues and PRs are welcome, but response times vary and not
every change will fit the scope.

## Ground rules

- **Open an issue first** for anything non-trivial, so we can agree on the approach
  before you write code.
- **Idempotency is the contract.** A clean second apply must report `changed=0`.
  Several tasks are gated or carry `changed_when` for exactly this reason — read the
  neighboring comment before simplifying one.
- **Respect the safety posture**: no DNS or default-route side-effects, restrictive
  defaults, secrets only via vault or gitignored vars, explicit change-gated restarts
  (no restart handlers — `handlers/main.yml` documents why). PRs that weaken these
  need to make the case explicitly.
- **No site-specific values in tracked files.** Real domains, IPs, and hostnames
  belong in gitignored `group_vars`; tracked files use placeholders
  (`headscale.example.com`, `192.0.2.10`).

## Dev setup

```bash
git clone https://github.com/vidaks/headscale-ansible && cd headscale-ansible
ansible-galaxy collection install -r requirements.yml
ansible-lint                        # production profile, must pass clean
ansible-playbook site.yml --syntax-check
```

Test on a Fedora host with Podman and a Traefik directory provider. The full loop:

```bash
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
ansible-playbook verify.yml
ansible-playbook site.yml           # must report changed=0
```

## Style & checks

- FQCN module names, named tasks, YAML-mapping arguments, `become` per task.
- Comments explain *why*, not *what* — match the density already in the files.
- CI runs `ansible-lint` (production profile) and playbook syntax checks. Both must
  pass before a PR is reviewed.

## Reporting bugs & security

- Bugs / features: use the issue templates.
- Security issues: **do not** open a public issue — see [SECURITY.md](SECURITY.md).

By contributing, you agree your contributions are licensed under the project's
[MIT License](LICENSE).
