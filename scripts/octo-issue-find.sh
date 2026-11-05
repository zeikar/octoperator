#!/usr/bin/env bash
# octo-issue-find.sh — find the open issues whose title or body contains a text, ignoring case.
#
# Usage:
#   octo-issue-find.sh --repo OWNER/NAME --text TEXT
#
# REST only: `gh issue list --search` uses GraphQL, which a Claude Code cloud session's proxy
# refuses, and REST issue search (`/search/issues`) is not known to pass that proxy. So it lists
# every open issue (`GET repos/OWNER/NAME/issues?state=open`, paginated, pull requests dropped)
# and matches TEXT as a plain string, not a pattern or a search query, so quotes, brackets, and
# other characters in a test name need no escaping. Line breaks and tabs in an issue count as
# spaces.
#
# Prints `<number> <url>` for each match, oldest first, or `none`.
# Exit codes: 0 listed (matches or none), 1 a gh error (gh's message on stderr), 2 bad arguments.
set -uo pipefail

REPO="" TEXT=""
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --text) need_value "$@"; TEXT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -n "$TEXT" ] || {
  echo "Usage: octo-issue-find.sh --repo OWNER/NAME --text TEXT" >&2; exit 2; }
case "$REPO" in
  */*/* | /* | */ | *[!A-Za-z0-9._/-]*) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
  */*) ;;
  *) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
esac
case "$TEXT" in
  *[[:cntrl:]]*) echo "--text must be one line" >&2; exit 2 ;;
esac

# One `<number> <url> <title and body>` line per issue; --jq runs on each page.
LIST=$(gh api "repos/$REPO/issues?state=open&sort=created&direction=asc&per_page=100" --paginate \
  --jq '.[] | select(.pull_request == null)
        | "\(.number) \(.html_url) \(.title // "") \(.body // "")" | gsub("[\\r\\n\\t]"; " ")') || {
  echo "octo-issue-find: could not list the open issues of $REPO" >&2; exit 1; }

found=0
shopt -s nocasematch
while read -r num url rest; do
  [ -n "$num" ] || continue
  # Quoted, the right side is a plain string, never a glob.
  if [[ "$rest" == *"$TEXT"* ]]; then
    echo "$num $url"; found=1
  fi
done <<<"$LIST"
[ "$found" -eq 1 ] || echo none
