#!/usr/bin/env bash
# headscale-upgrade.sh — check/apply Headscale (+headscale-ui) image upgrades
# Inputs:  args --apply (default report-only), --help
# Outputs: an upgrade report on stdout; on --apply, edits the role default pin,
#          deploys (site.yml) and gates on verify.yml, rolling back on failure.
# Exits:   0 success / nothing to do, 1 deploy-or-verify failure, 2 misuse
#
# Headscale is a container image pinned in roles/headscale/defaults/main.yml,
# not a DNF package — upgrading means bumping the pin and re-running Ansible.
# Headscale is pre-1.0: config schema and DB migrations break across MINOR
# versions and migrations run automatically on container start and are NOT
# reversible. So auto-apply is confined to PATCH releases within the current
# minor (image rollback is safe there); a new minor/major is only ever
# surfaced for manual review, never deployed unattended.
set -euo pipefail

# Run as the invoking user, not root: we use your gh auth for release lookups
# and your Ansible config; the playbook escalates via `become`/sudo itself,
# and the one local root op (DB backup) is wrapped in sudo.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: run as your regular user, not with sudo (uses your gh auth + Ansible)." >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULTS_FILE="$REPO_DIR/roles/headscale/defaults/main.yml"

APPLY=false
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=true ;;
        --help|-h)
            echo "Usage: $0 [--apply]"
            echo "  (no args)  report available upgrades, change nothing"
            echo "  --apply    deploy in-track (patch) upgrades, verify, roll back on failure"
            exit 0 ;;
        *) echo "ERROR: unknown argument '$arg' (see --help)" >&2; exit 2 ;;
    esac
done

# ── Component table ────────────────────────────────────────
# track_mode:
#   minor  — pre-1.0 semver; auto target = highest PATCH in current minor,
#            new minors/majors surfaced for manual review (migration risk).
#   latest — calver/static asset (no schema, no migration); auto = newest.
# version_var holds a BARE version string in defaults (image repo is separate).
#
# headscale-ui is intentionally absent: its headscale_ui_* defaults are unused
# scaffolding (no task/template consumes them, no quadlet installed). Add it
# back here with track_mode=latest only once the role actually deploys it.
declare -A GH_REPO=(     [headscale]="juanfont/headscale" )
declare -A VERSION_VAR=( [headscale]="headscale_version" )
declare -A TRACK_MODE=(  [headscale]="minor" )
COMPONENTS=(headscale)

# ── Helpers ────────────────────────────────────────────────
retry() { local n=0; until "$@"; do n=$((n+1)); ((n>=3)) && return 1; sleep 2; done; }

# Recent stable release tags (prereleases/drafts excluded), v-stripped, desc.
list_versions() {
    retry gh api "repos/$1/releases?per_page=100" \
        --jq '.[] | select(.prerelease==false and .draft==false) | .tag_name' 2>/dev/null \
        | sed 's/^v//' | grep -E '[0-9]' | sort -rV || true
}

# Read a bare quoted "var: \"value\"" pin from the defaults file.
get_pin() { grep -E "^$1:" "$DEFAULTS_FILE" | sed 's/[^"]*"\([^"]*\)".*/\1/'; }

# Replace a bare-string pin, then verify; revert and fail if it didn't take.
set_pin() {
    local var="$1" new="$2" before after esc
    before=$(get_pin "$var")
    esc=$(printf '%s\n' "$new" | sed 's/[&/\]/\\&/g')
    sed -i -E "s|^($var: \")[^\"]+(\".*)|\1$esc\2|" "$DEFAULTS_FILE"
    after=$(get_pin "$var")
    if [[ "$after" != "$new" ]]; then
        echo "ERROR: pin update failed for $var (got '$after')" >&2
        sed -i -E "s|^($var: \")[^\"]+(\".*)|\1$(printf '%s\n' "$before" | sed 's/[&/\]/\\&/g')\2|" "$DEFAULTS_FILE"
        return 1
    fi
}

# Anchored track regex for a minor line: "0.28.0" → ^0\.28\.
track_regex() { local mm; mm=$(echo "$1" | grep -oE '^[0-9]+\.[0-9]+'); printf '^%s\\.' "${mm//./\\.}"; }

# True if A sorts strictly above B.
ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$2" "$1" | sort -rV | head -1)" == "$1" ]]; }

# ── Preflight ──────────────────────────────────────────────
for t in gh jq ansible-playbook; do
    command -v "$t" >/dev/null || { echo "ERROR: missing required tool: $t" >&2; exit 2; }
done
[[ -f "$DEFAULTS_FILE" ]] || { echo "ERROR: defaults not found: $DEFAULTS_FILE" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: 'gh' is not authenticated (gh auth login)." >&2; exit 2; }

# ── Resolve each component: current / auto-target / manual-review ──
declare -A CUR AUTO REVIEW
for c in "${COMPONENTS[@]}"; do
    cur=$(get_pin "${VERSION_VAR[$c]}")
    CUR[$c]="$cur"
    mapfile -t cands < <(list_versions "${GH_REPO[$c]}")
    [[ ${#cands[@]} -eq 0 ]] && { echo "WARNING: release check failed for $c (${GH_REPO[$c]})" >&2; continue; }

    if [[ "${TRACK_MODE[$c]}" == "minor" ]]; then
        re=$(track_regex "$cur")
        in_track=$({ printf '%s\n' "${cands[@]}" | grep -E "$re" || true; } | sort -rV | head -1)
        above=$({ printf '%s\n' "${cands[@]}" | grep -vE "$re" || true; } | sort -rV | head -1)
        [[ -n "$in_track"  ]] && ver_gt "$in_track" "$cur" && AUTO[$c]="$in_track"
        [[ -n "$above"     ]] && ver_gt "$above"    "$cur" && REVIEW[$c]="$above"
    else
        latest="${cands[0]}"
        ver_gt "$latest" "$cur" && AUTO[$c]="$latest"
    fi
done

# ── Report ─────────────────────────────────────────────────
echo "Headscale upgrade check — $(date '+%Y-%m-%d %H:%M')"
echo "Repo: $REPO_DIR"
echo
printf '%-14s %-12s %-16s %s\n' "Component" "Current" "Auto (in-track)" "Manual review"
for c in "${COMPONENTS[@]}"; do
    review_cell=""
    [[ -n "${REVIEW[$c]:-}" ]] && review_cell="${REVIEW[$c]}  ← new minor/major"
    printf '%-14s %-12s %-16s %s\n' "$c" "${CUR[$c]:-?}" "${AUTO[$c]:-up-to-date}" "$review_cell"
done

# Manual-review guidance (new minor/major — migration risk, not auto-applied).
review_any=false
for c in "${COMPONENTS[@]}"; do [[ -n "${REVIEW[$c]:-}" ]] && review_any=true; done
if $review_any; then
    echo
    echo "Manual review required (NOT auto-applied — schema/DB migrations, not reversible):"
    for c in "${COMPONENTS[@]}"; do
        [[ -z "${REVIEW[$c]:-}" ]] && continue
        echo "  $c ${CUR[$c]} → ${REVIEW[$c]}"
        echo "    Notes: https://github.com/${GH_REPO[$c]}/releases/tag/v${REVIEW[$c]}"
        echo "    Apply: back up the DB, read the notes, then bump ${VERSION_VAR[$c]} and run"
        echo "           ansible-playbook site.yml && ansible-playbook verify.yml"
    done
fi

# ── Decide what --apply would touch (in-track only) ────────
declare -a TO_APPLY=()
for c in "${COMPONENTS[@]}"; do [[ -n "${AUTO[$c]:-}" ]] && TO_APPLY+=("$c"); done

if [[ ${#TO_APPLY[@]} -eq 0 ]]; then
    echo
    echo "No in-track upgrades to apply."
    exit 0
fi

if ! $APPLY; then
    echo
    echo "Report-only. Re-run with --apply to deploy the in-track upgrade(s):"
    for c in "${TO_APPLY[@]}"; do echo "  $c ${CUR[$c]} → ${AUTO[$c]}"; done
    exit 0
fi

# ── Apply ──────────────────────────────────────────────────
# site.yml deploys the whole role (no granular tags), so all eligible pins go
# in one deploy, gated by one verify, rolled back together on failure.
cd "$REPO_DIR"

# Best-effort DB snapshot before touching headscale itself. Cheap insurance;
# even a patch deploy restarts the container and replays any pending migration.
if printf '%s\n' "${TO_APPLY[@]}" | grep -qx headscale; then
    data_dir=$(get_pin headscale_data_dir); data_dir="${data_dir:-/mnt/config/headscale/data}"
    db="$data_dir/db.sqlite"
    bak="$data_dir/db.sqlite.bak-$(date +%Y%m%d-%H%M%S)"
    echo
    if sudo test -f "$db" && sudo cp -a "$db" "$bak"; then
        echo "DB backup: $bak"
    else
        echo "WARNING: DB backup skipped (could not read $db)" >&2
    fi
fi

declare -A ORIG
for c in "${TO_APPLY[@]}"; do
    ORIG[$c]="${CUR[$c]}"
    echo "Bumping ${VERSION_VAR[$c]}: ${CUR[$c]} → ${AUTO[$c]}"
    set_pin "${VERSION_VAR[$c]}" "${AUTO[$c]}"
done

rollback() {
    echo "Rolling back pins and redeploying previous version(s)..." >&2
    for c in "${TO_APPLY[@]}"; do set_pin "${VERSION_VAR[$c]}" "${ORIG[$c]}" || true; done
    ansible-playbook site.yml >/dev/null 2>&1 || echo "WARNING: rollback redeploy reported errors — check the host." >&2
}

echo "Deploying (ansible-playbook site.yml)..."
if ! ansible-playbook site.yml; then
    echo "ERROR: deploy failed." >&2
    rollback
    exit 1
fi

echo "Verifying (ansible-playbook verify.yml)..."
if ! ansible-playbook verify.yml; then
    echo "ERROR: verification failed after upgrade." >&2
    rollback
    if ansible-playbook verify.yml >/dev/null 2>&1; then
        echo "Rolled back to previous version; service verified healthy." >&2
    else
        echo "CRITICAL: rollback did not restore health — headscale may be DOWN." >&2
    fi
    exit 1
fi

echo
echo "Upgrade complete and verified:"
for c in "${TO_APPLY[@]}"; do echo "  $c ${ORIG[$c]} → ${AUTO[$c]}"; done
echo "Review 'git diff' and commit when ready (nothing is pushed by this script)."
