#!/usr/bin/env bash
# octo-setup.sh — probe the environment for Octoperator setup (read-only).
#
# Detects the repo + default branch and whether the token can access Projects v2 (read),
# listing any existing boards. Emits a single JSON object on stdout so the setup skill can
# decide whether to enable board features. Makes no changes.
#
# Usage:
#   octo-setup.sh [--repo OWNER/NAME] [--owner PROJECT_OWNER]
#
# Output JSON:
#   { "repo", "default_branch", "project_owner", "projects_capable", "boards":[{number,title,url}], "note" }
set -uo pipefail

REPO="" POWNER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="${2:-}"; shift 2 ;;
    --owner) POWNER="${2:-}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "{\"error\":\"unknown argument: $1\"}"; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo '{"error":"gh CLI not found"}'; exit 1; }
gh auth status >/dev/null 2>&1 || { echo '{"error":"not authenticated; run: gh auth login"}'; exit 1; }

[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
[ -n "$REPO" ] || { echo '{"error":"no repo: pass --repo OWNER/NAME or run inside a repo"}'; exit 1; }

DEFAULT=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "")
[ -n "$POWNER" ] || POWNER="${REPO%%/*}"

# Read-only Projects v2 capability probe: list boards for the owner.
# NOTE: success here means READ access only. A token can list projects yet still lack write
# (board creation / item edits) — write is proven only by attempting those operations, so the
# setup skill must handle a later create/edit failure gracefully.
ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT
if BOARDS=$(gh project list --owner "$POWNER" --format json --jq '[.projects[] | {number, title, url}]' 2>"$ERRF"); then
  CAPABLE=true
  NOTE=""
else
  CAPABLE=false
  BOARDS="[]"
  NOTE=$(tr -d '"\n' <"$ERRF" | cut -c1-200)
  [ -n "$NOTE" ] || NOTE="Projects not accessible (user-owned Projects v2 require a classic PAT with the project scope)."
fi

cat <<EOF
{
  "repo": "$REPO",
  "default_branch": "$DEFAULT",
  "project_owner": "$POWNER",
  "projects_capable": $CAPABLE,
  "boards": $BOARDS,
  "note": "$NOTE"
}
EOF
