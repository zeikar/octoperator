#!/usr/bin/env bash
# octo-ci-wait.sh — wait, bounded, for a commit's checks to finish, and say whether CI is green.
#
# Usage:
#   octo-ci-wait.sh --repo OWNER/NAME --sha HEAD_SHA [--timeout SECONDS] [--interval SECONDS]
#
# REST only, the stand-in for `gh pr checks --watch --fail-fast` (GraphQL, which a Claude Code
# cloud session refuses). Each poll reads the commit's check runs
# (`GET .../commits/SHA/check-runs?filter=latest`, every page) and its commit statuses (`GET
# .../commits/SHA/status`, every page, which lists the newest status per context), required
# and optional alike, from every workflow and app. A re-run leaves its older check runs behind,
# so only the newest check run of each name counts (the highest id), as `gh pr checks` keeps one
# per name.
#
# Each check counts as `gh pr checks` buckets it:
#   pass     check run completed as success, neutral, or skipped; status success
#   fail     check run completed as failure, cancelled, timed_out, or action_required; status
#            failure or error
#   pending  everything else: queued, in_progress, waiting, requested, or pending check runs, a
#            completed one that is stale or has no or an unknown conclusion; status pending
#
# Polls every --interval seconds (default 30) until a check fails, every check has passed, or
# --timeout seconds (default 540, at most 3600) would pass before the next poll; the wait lives
# here so a skill step stays one plain call. A failed read is retried at the next poll, at most
# twice in a row. Prints one line:
#   green              every check run and status passed
#   none               the commit has no check runs and no statuses
#   failed <names>     one or more failed (comma-separated), as soon as one is seen
#   pending <names>    still not finished at the timeout
# Read-only.
#
# Exit codes: 0 green or none, 1 failed or pending, 2 bad arguments, 3 a gh error (three reads in
# a row, or the last one before the timeout, failed).
set -uo pipefail

REPO="" SHA="" TIMEOUT=540 INTERVAL=30
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     need_value "$@"; REPO="$2"; shift 2 ;;
    --sha)      need_value "$@"; SHA="$2"; shift 2 ;;
    --timeout)  need_value "$@"; TIMEOUT="$2"; shift 2 ;;
    --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
USAGE="Usage: octo-ci-wait.sh --repo OWNER/NAME --sha HEAD_SHA [--timeout SECONDS] [--interval SECONDS]"
[ -n "$REPO" ] && [ -n "$SHA" ] || { echo "$USAGE" >&2; exit 2; }
case "$REPO" in
  */*/* | /* | */ | *[!A-Za-z0-9._/-]*) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
  */*) ;;
  *) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
esac
case "$SHA" in *[!0-9a-f]*) echo "--sha must be a full commit SHA" >&2; exit 2 ;; esac
[ "${#SHA}" -eq 40 ] || { echo "--sha must be a full commit SHA" >&2; exit 2; }
case "$TIMEOUT$INTERVAL" in
  *[!0-9]*) echo "--timeout and --interval must be non-negative integers" >&2; exit 2 ;;
esac
# Bounded: no wait longer than an hour, and no poll more often than once a second.
[ "${#TIMEOUT}" -le 4 ] && [ "$TIMEOUT" -le 3600 ] || { echo "--timeout must be at most 3600" >&2; exit 2; }
[ "${#INTERVAL}" -le 4 ] && [ "$INTERVAL" -ge 1 ] && [ "$INTERVAL" -le 3600 ] \
  || { echo "--interval must be from 1 to 3600" >&2; exit 2; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "mktemp failed" >&2; exit 3; }
trap 'rm -rf "$tmp"' EXIT

# read_checks : write $tmp/checks, one "<bucket><TAB><name>" line per check; 1 on a gh error,
# with gh's message in $tmp/err.
read_checks() {
  gh api --paginate "repos/$REPO/commits/$SHA/check-runs?filter=latest&per_page=100" \
    --jq '.check_runs[] | [.id, .name, .status, (.conclusion // "")] | @tsv' \
    >"$tmp/runs" 2>"$tmp/err" || return 1
  gh api --paginate "repos/$REPO/commits/$SHA/status?per_page=100" \
    --jq '.statuses[] | [.context, .state] | @tsv' >"$tmp/statuses" 2>"$tmp/err" || return 1
  {
    # Newest check run per name: highest id first, then the first of each name, listed back in
    # id order.
    LC_ALL=C sort -t "$(printf '\t')" -k1,1nr "$tmp/runs" | awk -F '\t' '
      !seen[$2]++ {
        if ($3 != "completed") b = "pending"
        else if ($4 ~ /^(success|neutral|skipped)$/) b = "pass"
        else if ($4 ~ /^(failure|cancelled|timed_out|action_required)$/) b = "fail"
        else b = "pending"
        print $1 "\t" b "\t" $2
      }' | LC_ALL=C sort -t "$(printf '\t')" -k1,1n | cut -f2-
    awk -F '\t' '{
      if ($2 == "success") b = "pass"
      else if ($2 ~ /^(failure|error)$/) b = "fail"
      else b = "pending"
      print b "\t" $1
    }' "$tmp/statuses"
  } >"$tmp/checks"
}
# names <bucket> : the names in that bucket, comma-separated.
names() { awk -F '\t' -v b="$1" '$1 == b { out = out (n++ ? ", " : "") $2 } END { print out }' "$tmp/checks"; }

deadline=$((SECONDS + TIMEOUT)) failed_reads=0 last=""
while :; do
  if read_checks; then
    failed_reads=0
    if [ ! -s "$tmp/checks" ]; then echo none; exit 0; fi
    bad="$(names fail)"
    if [ -n "$bad" ]; then echo "failed $bad"; exit 1; fi
    waiting="$(names pending)"
    if [ -z "$waiting" ]; then echo green; exit 0; fi
    last="pending $waiting"
  else
    failed_reads=$((failed_reads + 1))
    last=""
    [ "$failed_reads" -lt 3 ] || break
  fi
  [ $((SECONDS + INTERVAL)) -le "$deadline" ] || break
  sleep "$INTERVAL"
done
if [ -z "$last" ]; then
  cat "$tmp/err" >&2
  echo "Could not read the checks of $SHA" >&2
  exit 3
fi
echo "$last"
exit 1
