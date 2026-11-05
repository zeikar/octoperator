#!/usr/bin/env bash
# octo-ledger-read.sh — print the newest entry-shaped comments on autopilot's run ledger, for a
# human or `research` to read.
#
# Usage:
#   octo-ledger-read.sh --repo OWNER/NAME --issue LEDGER [--last N]
#
# REST only (`GET repos/OWNER/NAME/issues/LEDGER/comments`, paginated): a Claude Code cloud
# session's proxy refuses GraphQL, so no `gh issue view`. A comment is entry-shaped when its body
# holds ```json; it counts only from an OWNER, MEMBER, or COLLABORATOR
# (skills/autopilot/references/ledger.md). It parses no entry: octo-ledger-state.sh applies the
# rules.
#
# Prints one JSON object:
#   {"skipped": "<count> (<authorAssociation>), …", "entries": [{url, createdAt, authorAssociation, body}, …]}
# `entries` holds the newest N (default 20) entry-shaped comments from allowed authors, newest
# last; `skipped` counts the entry-shaped comments by other authors (an empty string for none).
# Exit codes: 0 printed, 1 a gh error (gh's message on stderr), 2 bad arguments.
set -uo pipefail

REPO="" ISSUE="" LAST=20
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  need_value "$@"; REPO="$2"; shift 2 ;;
    --issue) need_value "$@"; ISSUE="$2"; shift 2 ;;
    --last)  need_value "$@"; LAST="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -n "$ISSUE" ] || {
  echo "Usage: octo-ledger-read.sh --repo OWNER/NAME --issue LEDGER [--last N]" >&2; exit 2; }
case "$REPO" in
  */*/* | /* | */ | *[!A-Za-z0-9._/-]*) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
  */*) ;;
  *) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
esac
[[ "$ISSUE" =~ ^[1-9][0-9]{0,8}$ ]] && [[ "$LAST" =~ ^[1-9][0-9]{0,3}$ ]] || {
  echo "--issue and --last must be positive integers (--last at most 9999)" >&2; exit 2; }

# One `<authorAssociation><TAB><entry as compact JSON>` line per entry-shaped comment, oldest
# first. tojson escapes every control character, so each entry stays on its own line.
# shellcheck disable=SC2016  # backticks and \(...) belong to the jq filter
LINES=$(gh api "repos/$REPO/issues/$ISSUE/comments?per_page=100" --paginate \
  --jq '.[] | select((.body // "") | contains("```json"))
        | "\(.author_association)\t\({url: .html_url, createdAt: .created_at,
                                       authorAssociation: .author_association, body} | tojson)"') || {
  echo "octo-ledger-read: could not read the comments of #$ISSUE" >&2; exit 1; }

OK="" SKIPPED_ASSOC=""
nl=$'\n'
while IFS=$'\t' read -r assoc entry; do
  [ -n "$assoc" ] || continue
  case "$assoc" in
    OWNER | MEMBER | COLLABORATOR) OK="$OK$entry$nl" ;;
    *) SKIPPED_ASSOC="$SKIPPED_ASSOC$assoc$nl" ;;
  esac
done <<<"$LINES"

# "<count> (<association>)" per association, sorted by name, joined with ", ".
skipped=$(printf '%s' "$SKIPPED_ASSOC" | sort | uniq -c |
  awk '{ printf "%s%d (%s)", (NR > 1 ? ", " : ""), $1, $2 }')
entries=$(printf '%s' "$OK" | tail -n "$LAST" | paste -sd , -)
printf '{"skipped":"%s","entries":[%s]}\n' "$skipped" "$entries"
