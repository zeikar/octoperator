#!/usr/bin/env bash
# octo-merge-state.sh — print a PR's mergeStateStatus, waiting out GitHub's UNKNOWN.
#
# Usage:
#   octo-merge-state.sh --repo OWNER/NAME --pr NUMBER [--tries N] [--interval SECONDS]
#
# GitHub computes mergeability asynchronously, so a fresh query can return UNKNOWN. Queries up to
# --tries times (default 3), --interval seconds apart (default 10), stopping at the first answer
# that is not UNKNOWN, and prints the last mergeStateStatus (CLEAN, DIRTY, BLOCKED, BEHIND,
# UNSTABLE, UNKNOWN, …) on stdout. Exits 0 once a status was read, 1 on a gh error, 2 on bad
# arguments.
set -euo pipefail

REPO="" PR="" TRIES=3 INTERVAL=10
# Under `set -e` a bare `shift 2` past the last argument would exit 1 with no message.
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     need_value "$@"; REPO="$2"; shift 2 ;;
    --pr)       need_value "$@"; PR="$2"; shift 2 ;;
    --tries)    need_value "$@"; TRIES="$2"; shift 2 ;;
    --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -n "$PR" ] || {
  echo "Usage: octo-merge-state.sh --repo OWNER/NAME --pr NUMBER [--tries N] [--interval SECONDS]" >&2
  exit 2; }
case "$TRIES$INTERVAL" in
  *[!0-9]*) echo "--tries and --interval must be non-negative integers" >&2; exit 2 ;;
esac
[ "$TRIES" -ge 1 ] || { echo "--tries must be at least 1" >&2; exit 2; }

i=1
while :; do
  STATE=$(gh pr view "$PR" --repo "$REPO" --json mergeStateStatus --jq '.mergeStateStatus')
  if [ "$STATE" != "UNKNOWN" ] || [ "$i" -ge "$TRIES" ]; then break; fi
  i=$((i + 1))
  sleep "$INTERVAL"
done
echo "$STATE"
