#!/usr/bin/env bash
# octo-milestone-gate.sh — decide whether to plan the next milestone (`genesis --next`) now.
#
# Usage:
#   octo-milestone-gate.sh --repo OWNER/NAME --rate P/T|none --head SHA|none [--buildable N]
#                          [--failed-tip SHA|none] [--resume]
#
# --rate and --head are octo-evals-metric.sh's `rate:` and `head:` values, verbatim. --buildable
# is how many issues autopilot's discovery found it could build (default 0); --failed-tip is
# octo-ledger-state.sh's `planning-failed:` tip (default none); --resume is autopilot's flag.
# Planning needs all of these, checked in this order:
#   1. Nothing is buildable: ready work comes before a new milestone (no gh call).
#   2. No next-milestone PR is open: an open PR from this repo (not a fork) whose head branch
#      starts with `milestone-`, the branch genesis --next opens. At most one is open at a time.
#   3. Every eval passes: the rate is P/T with P == T.
#   4. The last run's planning did not fail at the default branch's current tip (--failed-tip):
#      a failure that would repeat waits for a new commit or --resume.
#   5. A human did not decline the last milestone at this tip: the newest closed or merged
#      next-milestone PR from this repo was closed unmerged, and nothing landed since. That is,
#      the tip is still the merge base of its head and the tip (nothing landed since it was
#      planned), or the tip's committer date is no later than the PR's closed_at (ready work
#      merged while it was open, before the human closed it). A compare that 404s (no common
#      ancestor) shares no base, so only the date can decide it. (A commit pushed after the
#      close with an older committer date also reads as declined.) A new commit, or --resume,
#      lifts it. (--resume does not lift step 4: octo-ledger-state.sh prints no failed tip then.)
#   6. The metric is fresh: the evals run it came from judged the tip (--head equals it). Right
#      after a milestone PR merges, the latest completed run still says P == T for the commit
#      before it, and planning then would file the milestone twice. When stale, it asks whether
#      a push or dispatch run of evals.yml for the tip is queued or in progress: `wait` if one is,
#      else `dispatch` (a `[skip ci]` push started none, so dispatching evals.yml is safe).
#
# Prints three lines:
#   milestone-pr: none | <number> <url>       (the lowest-numbered open next-milestone PR)
#   tip: <the default branch's tip commit> | unchecked
#   decision: build | open <number> | not all-pass | failed | declined <number> |
#             stale dispatch | stale wait <run id> | plan
# The tip is read only when steps 1 to 3 passed. Read-only, REST only (`gh api` GETs), so it works
# where GraphQL is refused (a Claude Code cloud session). For an empty repo REST still names a
# default branch, and reading its tip fails (exit 3), as before.
#
# Exit codes: 0 decided, 2 bad arguments, 3 a gh error (gh's output on stderr; nothing decided).
set -uo pipefail
# The dates compare as strings, byte by byte.
export LC_ALL=C

REPO="" RATE="" HEAD="" BUILDABLE=0 FAILED_TIP=none RESUME=false
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --rate) need_value "$@"; RATE="$2"; shift 2 ;;
    --head) need_value "$@"; HEAD="$2"; shift 2 ;;
    --buildable) need_value "$@"; BUILDABLE="$2"; shift 2 ;;
    --failed-tip) need_value "$@"; FAILED_TIP="$2"; shift 2 ;;
    --resume) RESUME=true; shift ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$RATE" ] && [ -n "$HEAD" ] || {
  echo "Usage: octo-milestone-gate.sh --repo OWNER/NAME --rate P/T|none --head SHA|none" \
    "[--buildable N] [--failed-tip SHA|none] [--resume]" >&2
  exit 2; }
# REPO goes into a jq filter as a string literal (gh's --jq has no --arg), so no quotes in it.
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || { echo "--repo must be OWNER/NAME" >&2; exit 2; }
int='(0|[1-9][0-9]{0,8})'
[[ "$BUILDABLE" =~ ^$int$ ]] || { echo "--buildable must be a whole number" >&2; exit 2; }
all_pass=no
if [ "$RATE" != none ]; then
  [[ "$RATE" =~ ^$int/$int$ ]] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] \
    && [ "${BASH_REMATCH[2]}" -ge 1 ] \
    || { echo "--rate must be P/T (whole numbers, P <= T, T >= 1) or none" >&2; exit 2; }
  [ "${BASH_REMATCH[1]}" -eq "${BASH_REMATCH[2]}" ] && all_pass=yes
fi
for v in "$HEAD" "$FAILED_TIP"; do
  [ "$v" = none ] || [[ "$v" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "--head and --failed-tip must be a 40-digit commit or none" >&2; exit 2; }
done

decide() { printf 'milestone-pr: %s\ntip: %s\ndecision: %s\n' "$1" "$2" "$3"; exit 0; }
[ "$BUILDABLE" -eq 0 ] || decide none unchecked build

err="$(mktemp)" && [ -n "$err" ] || { echo "mktemp failed" >&2; exit 3; }
trap 'rm -f "$err"' EXIT
# gh_failed <what> : gh's own error on stderr, exit 3.
gh_failed() { echo "$1 failed: $(grep -m 1 . "$err" || echo "exit status")" >&2; exit 3; }
# From this repo, not a fork (a deleted fork's head repo is null), on a milestone- branch.
mine='select(.head.repo.full_name == .base.repo.full_name
  and (.head.ref | startswith("milestone-")))'

prs="$(gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate \
  --jq ".[] | $mine | \"\(.number) \(.html_url)\"" 2>"$err")" \
  || gh_failed "listing open pull requests"
pr="$(printf '%s\n' "$prs" | grep . | sort -n | head -n 1)"
if [ -n "$pr" ]; then
  case "${pr%% *}" in '' | *[!0-9]*) echo "unexpected gh output: $pr" >&2; exit 3 ;; esac
  decide "$pr" unchecked "open ${pr%% *}"
fi
[ "$all_pass" = yes ] || decide none unchecked "not all-pass"

branch="$(gh api "repos/$REPO" --jq .default_branch 2>"$err")" || gh_failed "reading the repo"
[ -n "$branch" ] || { echo "gh printed no default branch" >&2; exit 3; }
tip="$(gh api "repos/$REPO/git/ref/heads/$branch" --jq .object.sha 2>"$err")" \
  || gh_failed "reading the tip of $branch"
[[ "$tip" =~ ^[0-9a-f]{40}$ ]] || { echo "unexpected tip from gh: $tip" >&2; exit 3; }
[ "$FAILED_TIP" != "$tip" ] || decide none "$tip" failed

if [ "$RESUME" = false ]; then
  # The newest closed or merged next-milestone PR (REST's closed state holds both), among the
  # 100 newest closed PRs.
  last="$(gh api "repos/$REPO/pulls?state=closed&sort=created&direction=desc&per_page=100" \
    --jq ".[] | $mine | \"\(.number) \(if .merged_at then \"MERGED\" else \"CLOSED\" end)\"
      + \" \(.head.sha) \(.closed_at)\"" 2>"$err")" || gh_failed "listing closed pull requests"
  last="$(printf '%s\n' "$last" | grep . | sort -n | tail -n 1)"
  read -r num state sha closed <<EOF
$last
EOF
  if [ "${state:-}" = CLOSED ]; then
    case "$num" in '' | *[!0-9]*) echo "unexpected gh output: $last" >&2; exit 3 ;; esac
    [[ "${sha:-}" =~ ^[0-9a-f]{40}$ ]] || { echo "unexpected head from gh: $last" >&2; exit 3; }
    date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    [[ "${closed:-}" =~ $date_re ]] || { echo "unexpected closed_at from gh: $last" >&2; exit 3; }
    if base="$(gh api "repos/$REPO/compare/$tip...$sha" --jq .merge_base_commit.sha 2>"$err")"
    then [ "$base" != "$tip" ] || decide none "$tip" "declined $num"
    else grep -q 'HTTP 404' "$err" || gh_failed "comparing PR #$num with $branch"
    fi
    when="$(gh api "repos/$REPO/git/commits/$tip" --jq .committer.date 2>"$err")" \
      || gh_failed "reading the date of $branch's tip"
    [[ "$when" =~ $date_re ]] || { echo "unexpected commit date from gh: $when" >&2; exit 3; }
    [[ "$when" > "$closed" ]] || decide none "$tip" "declined $num"
  fi
fi

[ "$HEAD" != "$tip" ] || decide none "$tip" plan
run="$(gh api -X GET "repos/$REPO/actions/workflows/evals.yml/runs" -f branch="$branch" \
  -f head_sha="$tip" -f per_page=20 \
  --jq '[.workflow_runs[] | select(.status != "completed")
          | select(.event == "push" or .event == "workflow_dispatch")
          | select((.head_repository.full_name // "" | ascii_downcase)
                   == ("'"$REPO"'" | ascii_downcase))]
        | .[0] // empty | .id' 2>"$err")" || gh_failed "listing evals.yml runs for the tip"
[ -n "$run" ] || decide none "$tip" "stale dispatch"
case "$run" in *[!0-9]*) echo "unexpected run id from gh: $run" >&2; exit 3 ;; esac
decide none "$tip" "stale wait $run"
