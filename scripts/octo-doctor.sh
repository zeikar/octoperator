#!/usr/bin/env bash
# octo-doctor.sh — verify Octoperator prerequisites and print board Status options.
#
# Usage:
#   octo-doctor.sh --repo OWNER/NAME [--project NUMBER] [--owner PROJECT_OWNER]
#
# Checks: gh installed, gh authenticated, repo readable, (optionally) project readable,
# and prints the project's Status single-select options so settings can be confirmed.
# Projects v2 has no REST API: where GraphQL is refused (a Claude Code cloud session's proxy), the
# project checks are skipped with one `• Projects unavailable here ...` line, not a failure.
# Exit code is non-zero if any required check fails.
set -euo pipefail

REPO="" PROJECT="" POWNER=""
# Under `set -e` a bare `shift 2` past the last argument would exit 1 with no message.
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    need_value "$@"; REPO="$2"; shift 2 ;;
    --project) need_value "$@"; PROJECT="$2"; shift 2 ;;
    --owner)   need_value "$@"; POWNER="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "✗ $1" >&2; exit 1; }
ok()   { echo "✓ $1"; }

command -v gh >/dev/null 2>&1 || fail "gh CLI not found. Install: https://cli.github.com"
ok "gh CLI present ($(gh --version | head -1))"

# No `gh auth status` gate: it checks every stored host and token, so it can fail where the token
# in use works (a Claude Code cloud session's). Reading the user is the real probe.
ME=$(gh api user --jq '.login' 2>&1) \
  || fail "Could not read the authenticated user (not authenticated? gh auth login): ${ME:0:200}"
ok "Authenticated as @$ME"

[ -n "$REPO" ] || fail "Missing --repo OWNER/NAME"
# REST (works where GraphQL is refused, as in a Claude Code cloud session). The Projects v2
# checks below have no REST API.
DEFAULT=$(gh api "repos/$REPO" --jq '.default_branch' 2>/dev/null) \
  || fail "Cannot access repo: $REPO"
ok "Repo $REPO reachable (default branch: $DEFAULT)"

ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT
[ -n "$POWNER" ] || POWNER="${REPO%%/*}"
if [ -z "$PROJECT" ]; then
  echo "• No --project given; skipped project checks."
elif ! gh project view "$PROJECT" --owner "$POWNER" --format json >/dev/null 2>"$ERRF"; then
  # The cloud proxy's refusal is no failure: no token or scope fixes it. Anything else is.
  if ! grep -Fq 'GitHub GraphQL is not available from Claude Code sessions' "$ERRF"; then
    echo "✗ Cannot access project #$PROJECT (owner: $POWNER)." >&2
    echo "  If this is a scope error, run: gh auth refresh -s project" >&2
    exit 1
  fi
  echo "• Projects unavailable here (Projects v2 needs GraphQL, which this session refuses);" \
    "skipped project checks."
else
  TITLE=$(gh project view "$PROJECT" --owner "$POWNER" --format json --jq '.title')
  ok "Project #$PROJECT \"$TITLE\" reachable (owner: $POWNER)"
  echo "  Status options:"
  # A missing field is not an error to jq — the select just emits nothing — so tell a failed read
  # apart from an empty result instead of relying on the exit code alone.
  if ! OPTIONS=$(gh project field-list "$PROJECT" --owner "$POWNER" --limit 100 --format json \
       --jq '.fields[] | select(.name=="Status") | .options[]?.name' 2>/dev/null); then
    echo "    (could not read the project's fields — check the project scope)" >&2
  elif [ -z "$OPTIONS" ]; then
    echo "    (no single-select field named \"Status\" with options — the board needs one)" >&2
  else
    printf '%s\n' "$OPTIONS" | sed 's/^/    - /'
  fi
fi

echo "Doctor checks passed."
