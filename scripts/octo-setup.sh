#!/usr/bin/env bash
# octo-setup.sh — probe the environment for Octoperator setup (read-only).
#
# Detects the repo + default branch and whether the token can access Projects v2 (read),
# listing any existing boards. Emits a single JSON object on stdout so the setup skill can
# decide whether to enable board features. Makes no changes. The repo reads are REST
# (`gh api repos/...`; with no --repo, gh fills `{owner}/{repo}` from the git remote), so they
# work where GraphQL is refused (a Claude Code cloud session); the Projects v2 probe has no REST
# API, so there it reports `projects_capable: false` with the note `Projects unavailable here:
# ...` (the proxy's GraphQL 403), and the board is skipped. REST names a default branch even for
# an empty repo.
#
# Usage:
#   octo-setup.sh [--repo OWNER/NAME] [--owner PROJECT_OWNER]
#
# Output JSON:
#   { "repo", "default_branch", "project_owner", "projects_capable", "boards":[{number,title,url}], "note" }
#   or, on failure, { "error", "detail" } (detail: gh's own message, when gh failed) and exit 1.
set -uo pipefail

REPO="" POWNER=""
# No `set -e` here, so a failed `shift 2` (flag given without a value) would loop forever.
need_value() { [ $# -ge 2 ] || { echo "{\"error\":\"missing value for $1\"}"; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  need_value "$@"; REPO="$2"; shift 2 ;;
    --owner) need_value "$@"; POWNER="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "{\"error\":\"unknown argument: $1\"}"; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo '{"error":"gh CLI not found"}'; exit 1; }

ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT
# gh's stderr, made safe for a JSON string in any locale: printable ASCII only, no quotes or
# backslashes, no trailing spaces, and at most 200 bytes.
detail() {
  LC_ALL=C tr '\n\r\t' '   ' <"$ERRF" | LC_ALL=C tr -cd ' -~' | LC_ALL=C tr -d '"\\' \
    | LC_ALL=C cut -c1-200 | LC_ALL=C sed 's/ *$//'
}
# fail <message> : print the error JSON, with gh's stderr as its detail, and exit 1.
fail() { printf '{"error":"%s","detail":"%s"}\n' "$1" "$(detail)"; exit 1; }

# No `gh auth status` gate: it checks every stored host and token, so it can fail where the token
# this run uses works (a Claude Code cloud session's). The repo lookups below are the real probe,
# and a failure reports gh's own message.
if [ -z "$REPO" ]; then
  REPO=$(gh api 'repos/{owner}/{repo}' --jq '.full_name' 2>"$ERRF") \
    || fail "no repo: pass --repo OWNER/NAME or run inside a repo (or gh is not authenticated)"
fi
[ -n "$REPO" ] || fail "no repo: pass --repo OWNER/NAME or run inside a repo"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || { echo '{"error":"--repo must be OWNER/NAME"}'; exit 2; }

DEFAULT=$(gh api "repos/$REPO" --jq '.default_branch' 2>"$ERRF") \
  || fail "cannot read $REPO (not found, no access, or gh is not authenticated: gh auth login)"
[ -n "$POWNER" ] || POWNER="${REPO%%/*}"
[[ "$POWNER" =~ ^[A-Za-z0-9-]+$ ]] || { echo '{"error":"--owner must be a GitHub login"}'; exit 2; }

# Read-only Projects v2 capability probe: list boards for the owner.
# NOTE: success here means READ access only. A token can list projects yet still lack write
# (board creation / item edits) — write is proven only by attempting those operations, so the
# setup skill must handle a later create/edit failure gracefully.
# gh lists at most 30 projects by default; raise it so busy owners are not cut off at 30.
if BOARDS=$(gh project list --owner "$POWNER" --limit 100 --format json \
     --jq '[.projects[] | {number, title, url}]' 2>"$ERRF"); then
  CAPABLE=true
  NOTE=""
elif grep -Fq 'GitHub GraphQL is not available from Claude Code sessions' "$ERRF"; then
  # The cloud proxy's refusal: no token or scope fixes it, so say that rather than gh's message.
  CAPABLE=false
  BOARDS="[]"
  NOTE="Projects unavailable here: Projects v2 has no REST API and this session refuses GraphQL (a Claude Code cloud session). The board is skipped."
else
  CAPABLE=false
  BOARDS="[]"
  NOTE=$(detail)
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
