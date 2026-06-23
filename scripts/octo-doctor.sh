#!/usr/bin/env bash
# octo-doctor.sh — verify Octoperator prerequisites and print board Status options.
#
# Usage:
#   octo-doctor.sh --repo OWNER/NAME [--project NUMBER] [--owner PROJECT_OWNER]
#
# Checks: gh installed, gh authenticated, repo readable, (optionally) project readable,
# and prints the project's Status single-select options so settings can be confirmed.
# Exit code is non-zero if any required check fails.
set -euo pipefail

REPO="" PROJECT="" POWNER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --owner)   POWNER="${2:-}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "✗ $1" >&2; exit 1; }
ok()   { echo "✓ $1"; }

command -v gh >/dev/null 2>&1 || fail "gh CLI not found. Install: https://cli.github.com"
ok "gh CLI present ($(gh --version | head -1))"

gh auth status >/dev/null 2>&1 || fail "Not authenticated. Run: gh auth login"
ME=$(gh api user --jq '.login' 2>/dev/null) || fail "Could not read authenticated user."
ok "Authenticated as @$ME"

[ -n "$REPO" ] || fail "Missing --repo OWNER/NAME"
gh repo view "$REPO" --json nameWithOwner >/dev/null 2>&1 || fail "Cannot access repo: $REPO"
DEFAULT=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
ok "Repo $REPO reachable (default branch: $DEFAULT)"

if [ -n "$PROJECT" ]; then
  [ -n "$POWNER" ] || POWNER="${REPO%%/*}"
  if ! gh project view "$PROJECT" --owner "$POWNER" --format json >/dev/null 2>&1; then
    echo "✗ Cannot access project #$PROJECT (owner: $POWNER)." >&2
    echo "  If this is a scope error, run: gh auth refresh -s project" >&2
    exit 1
  fi
  TITLE=$(gh project view "$PROJECT" --owner "$POWNER" --format json --jq '.title')
  ok "Project #$PROJECT \"$TITLE\" reachable (owner: $POWNER)"
  echo "  Status options:"
  if ! gh project field-list "$PROJECT" --owner "$POWNER" --format json \
       --jq '.fields[] | select(.name=="Status") | .options[].name' 2>/dev/null \
       | sed 's/^/    - /'; then
    echo "    (no single-select field named \"Status\" found — set statuses in settings)" >&2
  fi
else
  echo "• No --project given; skipped project checks."
fi

echo "Doctor checks passed."
