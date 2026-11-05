#!/usr/bin/env bash
# octo-merge-state.sh — print a PR's merge state, waiting out GitHub's UNKNOWN.
#
# Usage:
#   octo-merge-state.sh --repo OWNER/NAME --pr NUMBER [--tries N] [--interval SECONDS]
#
# Reads REST's `mergeable_state` (`GET repos/OWNER/NAME/pulls/N`), so it works where GraphQL is
# refused (a Claude Code cloud session), and prints it uppercased, the names auto's gate has always
# used: clean → CLEAN, dirty → DIRTY, blocked → BLOCKED, behind → BEHIND, unstable → UNSTABLE,
# has_hooks → HAS_HOOKS, draft → DRAFT, and any other lowercase value as itself, uppercased. Only
# CLEAN merges; every other value holds, HAS_HOOKS included (mergeable, but behind pre-receive
# hooks: GraphQL's HAS_HOOKS was never CLEAN either).
#
# GitHub computes the state lazily: a read can return null or `unknown` while it works, and the
# read itself starts the work. Both print as UNKNOWN. Queries up to --tries times (default 3),
# --interval seconds apart (default 10), stopping at the first answer that is not UNKNOWN, and
# prints the last one on stdout. Exits 0 once a state was read, 1 on a gh error (whatever gh's own
# exit code) or a value that is not a lowercase word, 2 on bad arguments.
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
case "$PR" in *[!0-9]*) echo "--pr must be a number" >&2; exit 2 ;; esac
case "$TRIES$INTERVAL" in
  *[!0-9]*) echo "--tries and --interval must be non-negative integers" >&2; exit 2 ;;
esac
[ "$TRIES" -ge 1 ] || { echo "--tries must be at least 1" >&2; exit 2; }

i=1
while :; do
  # `|| exit 1`: under `set -e` gh's own exit code would leak out, and gh's 2 would look like
  # this script's bad-arguments 2.
  RAW=$(gh api "repos/$REPO/pulls/$PR" --jq '.mergeable_state // "unknown"') || exit 1
  case "$RAW" in
    # Letters spelled out: a range like a-z can match capitals outside the C locale.
    '' | *[!abcdefghijklmnopqrstuvwxyz_]*) echo "Unexpected mergeable_state: '$RAW'" >&2; exit 1 ;;
  esac
  STATE=$(printf '%s' "$RAW" | LC_ALL=C tr '[:lower:]' '[:upper:]')
  if [ "$STATE" != "UNKNOWN" ] || [ "$i" -ge "$TRIES" ]; then break; fi
  i=$((i + 1))
  sleep "$INTERVAL"
done
echo "$STATE"
