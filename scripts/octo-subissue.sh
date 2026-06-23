#!/usr/bin/env bash
# octo-subissue.sh — link a child issue to a parent epic as a native GitHub sub-issue.
#
# Usage:
#   octo-subissue.sh --repo OWNER/NAME --parent <epic#> --child <child#>
#
# Exits 0 on success. Exits non-zero if the sub-issue API is unavailable or the call fails,
# so the caller can fall back to a task-list entry in the epic body.
set -euo pipefail

REPO="" PARENT="" CHILD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="${2:-}"; shift 2 ;;
    --parent) PARENT="${2:-}"; shift 2 ;;
    --child)  CHILD="${2:-}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -n "$PARENT" ] && [ -n "$CHILD" ] || {
  echo "Usage: octo-subissue.sh --repo OWNER/NAME --parent <epic#> --child <child#>" >&2; exit 2; }

OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

node_id() {
  gh api graphql \
    -f query='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}' \
    -F o="$OWNER" -F n="$NAME" -F num="$1" --jq '.data.repository.issue.id'
}

PID=$(node_id "$PARENT") || { echo "Could not resolve epic #$PARENT" >&2; exit 1; }
CID=$(node_id "$CHILD")  || { echo "Could not resolve child #$CHILD" >&2; exit 1; }

# The sub_issues GraphQL feature header is harmless once the feature is GA.
if gh api graphql -H "GraphQL-Features: sub_issues" \
     -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' \
     -F p="$PID" -F c="$CID" >/dev/null 2>&1; then
  echo "Linked #$CHILD as sub-issue of #$PARENT"
  exit 0
fi

echo "Sub-issue API unavailable; caller should fall back to a task-list entry." >&2
exit 1
