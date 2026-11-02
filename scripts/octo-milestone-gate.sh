#!/usr/bin/env bash
# octo-milestone-gate.sh — decide whether to plan the next milestone (`genesis --next`) now.
#
# Usage:
#   octo-milestone-gate.sh --repo OWNER/NAME --rate P/T|none --head SHA|none
#
# --rate and --head are octo-evals-metric.sh's `rate:` and `head:` values, verbatim. Planning
# needs all three of these, checked in this order:
#   1. No next-milestone PR is open: an open PR from this repo (not a fork) whose head branch
#      starts with `milestone-`, the branch genesis --next opens. At most one is open at a time.
#   2. Every eval passes: the rate is P/T with P == T.
#   3. The metric is fresh: the evals run it came from judged the default branch's current tip
#      (--head equals the tip). Right after a milestone PR merges, the latest completed run still
#      says P == T for the commit before it, and planning then would file the milestone twice.
#
# Prints three lines:
#   milestone-pr: none | <number> <url>       (the lowest-numbered open next-milestone PR)
#   tip: <the default branch's tip commit> | unchecked
#   decision: open <number> | not all-pass | stale | plan
# The tip is read only when steps 1 and 2 passed. Read-only: `gh pr list`, `gh repo view`, and
# one `gh api` GET.
#
# Exit codes: 0 decided, 2 bad arguments, 3 a gh error (gh's output on stderr; nothing decided).
set -uo pipefail

REPO="" RATE="" HEAD=""
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --rate) need_value "$@"; RATE="$2"; shift 2 ;;
    --head) need_value "$@"; HEAD="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$RATE" ] && [ -n "$HEAD" ] || {
  echo "Usage: octo-milestone-gate.sh --repo OWNER/NAME --rate P/T|none --head SHA|none" >&2
  exit 2; }
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || { echo "--repo must be OWNER/NAME" >&2; exit 2; }
int='(0|[1-9][0-9]{0,8})'
all_pass=no
if [ "$RATE" != none ]; then
  [[ "$RATE" =~ ^$int/$int$ ]] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] \
    && [ "${BASH_REMATCH[2]}" -ge 1 ] \
    || { echo "--rate must be P/T (whole numbers, P <= T, T >= 1) or none" >&2; exit 2; }
  [ "${BASH_REMATCH[1]}" -eq "${BASH_REMATCH[2]}" ] && all_pass=yes
fi
[ "$HEAD" = none ] || [[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "--head must be a 40-digit commit or none" >&2; exit 2; }

err="$(mktemp)" && [ -n "$err" ] || { echo "mktemp failed" >&2; exit 3; }
trap 'rm -f "$err"' EXIT
# gh_failed <what> : gh's own error on stderr, exit 3.
gh_failed() { echo "$1 failed: $(grep -m 1 . "$err" || echo "exit status")" >&2; exit 3; }
decide() { printf 'milestone-pr: %s\ntip: %s\ndecision: %s\n' "$1" "$2" "$3"; exit 0; }

prs="$(gh pr list --repo "$REPO" --state open --limit 200 \
  --json number,url,headRefName,isCrossRepository \
  --jq '.[] | select((.isCrossRepository | not) and (.headRefName | startswith("milestone-")))
        | "\(.number) \(.url)"' 2>"$err")" || gh_failed "gh pr list"
pr="$(printf '%s\n' "$prs" | grep . | sort -n | head -n 1)"
if [ -n "$pr" ]; then
  case "${pr%% *}" in '' | *[!0-9]*) echo "unexpected gh output: $pr" >&2; exit 3 ;; esac
  decide "$pr" unchecked "open ${pr%% *}"
fi
[ "$all_pass" = yes ] || decide none unchecked "not all-pass"

branch="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name 2>"$err")" \
  || gh_failed "gh repo view"
[ -n "$branch" ] || { echo "gh printed no default branch" >&2; exit 3; }
tip="$(gh api "repos/$REPO/git/ref/heads/$branch" --jq .object.sha 2>"$err")" \
  || gh_failed "reading the tip of $branch"
[[ "$tip" =~ ^[0-9a-f]{40}$ ]] || { echo "unexpected tip from gh: $tip" >&2; exit 3; }
[ "$HEAD" = "$tip" ] || decide none "$tip" stale
decide none "$tip" plan
