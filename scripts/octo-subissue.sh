#!/usr/bin/env bash
# octo-subissue.sh — link a child issue to a parent epic as a native GitHub sub-issue.
#
# Usage:
#   octo-subissue.sh --repo OWNER/NAME --parent <epic#> --child <child#>
#
# Exits 0 on success. Exits non-zero if the sub-issue API is unavailable or the call fails
# (printing GitHub's error on stderr), so the caller can fall back to a task-list entry in the
# epic body.
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

OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

node_id() {
  # shellcheck disable=SC2016  # $o/$n/$num are GraphQL variables — must stay literal, not shell-expanded
  gh api graphql \
    -f query='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}' \
    -f o="$OWNER" -f n="$NAME" -F num="$1" --jq '.data.repository.issue.id'
}

PID=$(node_id "$PARENT") || { echo "Could not resolve epic #$PARENT" >&2; exit 1; }
CID=$(node_id "$CHILD")  || { echo "Could not resolve child #$CHILD" >&2; exit 1; }

# The sub_issues GraphQL feature header is harmless once the feature is GA.
# Keep gh's stderr: the real cause (already has a parent, permissions, limits, API missing)
# matters to the caller and must not be collapsed into one generic message.
# shellcheck disable=SC2016  # $p/$c are GraphQL variables — must stay literal, not shell-expanded
if ERR=$(gh api graphql -H "GraphQL-Features: sub_issues" \
     -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' \
     -f p="$PID" -f c="$CID" 2>&1 >/dev/null); then
  echo "Linked #$CHILD as sub-issue of #$PARENT"
  exit 0
fi

echo "addSubIssue failed for #$CHILD -> #$PARENT: ${ERR:-no error output from gh}" >&2
echo "Caller should fall back to a task-list entry." >&2
exit 1
