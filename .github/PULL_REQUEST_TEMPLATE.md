<!-- Thanks for contributing! Keep PRs focused — one concern each. -->

## What & why

<!-- What does this change, and why? Link any related issue (Fixes #…). -->

## Checklist

- [ ] Discussed in an issue first (for non-trivial changes)
- [ ] `ansible-lint` passes clean (production profile)
- [ ] Preserves the posture (no DNS/route side-effects, restrictive defaults,
      change-gated restarts, changed=0 on a clean re-apply)
- [ ] No site-specific values in tracked files (placeholders only)
- [ ] Applied on a real host: `site.yml` → `verify.yml` → re-apply reports changed=0
- [ ] Updated `README.md` if behavior or variables changed

## Notes / test output

<!-- Paste the verify.yml summary or relevant output. Do NOT include real domains,
     IPs, or pre-auth keys. -->
