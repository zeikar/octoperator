#!/usr/bin/env bash
# octo-subissue.sh — link a child issue to a parent epic as a native GitHub sub-issue.
#
# Usage:
#   octo-subissue.sh --repo OWNER/NAME --parent <epic#> --child <child#>
#
# REST only (`gh api repos/...`): a Claude Code cloud session's proxy refuses GraphQL. It reads
# both issues (`GET .../issues/N`), then links the child by its numeric `id`
# (`POST .../issues/<epic#>/sub_issues` with `sub_issue_id`).
#
# Exits 0 on success. Exits 1 if either issue can't be read or the link fails (printing GitHub's
# error on stderr), so the caller can fall back to a task-list entry in the epic body; exits 2 on
# bad arguments.
set -euo pipefail

REPO="" PARENT="" CHILD=""
# Under `set -e` a bare `shift 2` past the last argument would exit 1 with no message.
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   need_value "$@"; REPO="$2"; shift 2 ;;
    --parent) need_value "$@"; PARENT="$2"; shift 2 ;;
    --child)  need_value "$@"; CHILD="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -n "$PARENT" ] && [ -n "$CHILD" ] || {
  echo "Usage: octo-subissue.sh --repo OWNER/NAME --parent <epic#> --child <child#>" >&2; exit 2; }
# The values go into REST paths, so nothing but OWNER/NAME and plain issue numbers.
case "$REPO" in
  */*/* | /* | */ | *[!A-Za-z0-9._/-]*) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
  */*) ;;
  *) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
esac
for n in "$PARENT" "$CHILD"; do
  [[ "$n" =~ ^[1-9][0-9]{0,8}$ ]] || {
    echo "--parent and --child must be issue numbers (1 to 9 digits, no leading zero)" >&2; exit 2; }
done

# The REST `id` (a number), which sub_issue_id takes; not the issue number or the node id.
issue_id() { gh api "repos/$REPO/issues/$1" --jq '.id'; }

issue_id "$PARENT" >/dev/null || { echo "Could not resolve epic #$PARENT" >&2; exit 1; }
CID=$(issue_id "$CHILD") || { echo "Could not resolve child #$CHILD" >&2; exit 1; }

# Keep gh's stderr: the real cause (already has a parent, permissions, limits, API missing)
# matters to the caller and must not be collapsed into one generic message. -F sends the id as a
# number, which the endpoint requires.
if ERR=$(gh api "repos/$REPO/issues/$PARENT/sub_issues" -F sub_issue_id="$CID" 2>&1 >/dev/null); then
  echo "Linked #$CHILD as sub-issue of #$PARENT"
  exit 0
fi

echo "Sub-issue link failed for #$CHILD -> #$PARENT: ${ERR:-no error output from gh}" >&2
echo "Caller should fall back to a task-list entry." >&2
exit 1
