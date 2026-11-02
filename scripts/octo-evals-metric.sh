#!/usr/bin/env bash
# octo-evals-metric.sh — read the evals pass rate that autopilot records as the ledger `metric`.
#
# Usage:
#   octo-evals-metric.sh --repo OWNER/NAME
#
# A repo has the evals workflow when its default branch holds .github/workflows/evals.yml (the
# file genesis writes; its name, "Evals", is the repo's to change). The metric comes from that
# workflow's latest completed run on the default branch that a `push` or `workflow_dispatch` in
# this repo started (of the newest 20 completed runs there, so a fork's `pull_request` run from
# its own main never counts): across the run's jobs (latest attempt), exactly one `notice`
# check-run annotation titled `evals-metric` whose message is exactly `passed=<P> total=<T>`,
# whole numbers with P <= T and T >= 1. run.sh exits 0 exactly when P == T, so the run's
# conclusion must agree: `success` when P == T, `failure` when P < T. Anything else (no such run,
# no annotation, more than one, a malformed message, P > T, T = 0, a conclusion that disagrees,
# or a gh error) is unreadable.
#
# Prints three lines:
#   metric: {"passed":P,"total":T}   or   metric: null
#   rate: P/T                        or   rate: none      (octo-ledger-state.sh's --metric value)
#   source: run <id> (<conclusion>) <url>: P/T evals pass
#           no evals workflow
#           unreadable: <reason>
# Read-only: `gh repo view` and `gh api` GETs.
#
# Exit codes: 0 whenever it printed a metric line (null included), 2 bad arguments.
set -uo pipefail

REPO=""
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { echo "Usage: octo-evals-metric.sh --repo OWNER/NAME" >&2; exit 2; }
# REPO goes into a jq filter as a string literal (gh's --jq has no --arg), so no quotes in it.
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || { echo "--repo must be OWNER/NAME" >&2; exit 2; }

WF=evals.yml
# none <source> : no metric, and why; the run goes on either way.
none() { echo "metric: null"; echo "rate: none"; echo "source: $1"; exit 0; }
err="$(mktemp)" && [ -n "$err" ] || none "unreadable: mktemp failed"
trap 'rm -f "$err"' EXIT
# gh_failed : no metric, with the first line gh wrote to $err. Called in this shell, never in a
# $(…), so its exit ends the script rather than a subshell.
gh_failed() { none "unreadable: gh error: $(grep -m 1 . "$err" || echo "exit status")"; }

branch="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name 2>"$err")" \
  || gh_failed
[ -n "$branch" ] || none "unreadable: gh printed no default branch"
if ! gh api -X GET "repos/$REPO/contents/.github/workflows/$WF" -f ref="$branch" --jq .type \
    >/dev/null 2>"$err"; then
  grep -q 'HTTP 404' "$err" && none "no evals workflow"
  gh_failed
fi

# gh's -f encodes the branch into the query string. A workflow GitHub never registered (the file
# landed but no run started) is a 404 here: there is no completed run either way. A run's
# head_branch alone can't tell this repo's main from a fork's, so keep only push and dispatch
# runs whose head repository is this one (GitHub names compare case-insensitively).
nomatch="unreadable: no completed push or dispatch run of $WF on $branch (newest 20 checked)"
if ! run="$(gh api -X GET "repos/$REPO/actions/workflows/$WF/runs" -f branch="$branch" \
    -f status=completed -f per_page=20 \
    --jq '[.workflow_runs[] | select(.event == "push" or .event == "workflow_dispatch")
            | select((.head_repository.full_name // "" | ascii_downcase)
                     == ("'"$REPO"'" | ascii_downcase))]
          | .[0] // empty | [.id, (.conclusion // "none"), .html_url] | @tsv' \
    2>"$err")"; then
  grep -q 'HTTP 404' "$err" && none "$nomatch"
  gh_failed
fi
[ -n "$run" ] || none "$nomatch"
IFS=$'\t' read -r id conclusion url <<EOF
$run
EOF
case "$id" in '' | *[!0-9]*) none "unreadable: unexpected run id from gh" ;; esac
where="run $id ($conclusion) $url"

checks="$(gh api --paginate "repos/$REPO/actions/runs/$id/jobs?filter=latest&per_page=100" \
  --jq '.jobs[] | .check_run_url | sub(".*/"; "")' 2>"$err")" || gh_failed
# One JSON string per annotation, so a message holding a newline still counts once.
msgs=""
for cr in $checks; do
  case "$cr" in *[!0-9]*) none "unreadable: unexpected check run URL on $where" ;; esac
  m="$(gh api --paginate "repos/$REPO/check-runs/$cr/annotations?per_page=100" \
    --jq '.[] | select(.title == "evals-metric" and .annotation_level == "notice") | .message
      | tojson' 2>"$err")" || gh_failed
  [ -z "$m" ] || msgs="$msgs$m"$'\n'
done

n="$(printf '%s' "$msgs" | grep -c .)"
[ "$n" -gt 0 ] || none "unreadable: no evals-metric annotation on $where"
[ "$n" -eq 1 ] || none "unreadable: $n evals-metric annotations on $where (ambiguous)"
msg="${msgs%$'\n'}"
# At most 9 digits and no leading zero: no octal, no overflow in the comparison below.
int='(0|[1-9][0-9]{0,8})'
if ! [[ "$msg" =~ ^\"passed=${int}\ total=${int}\"$ ]]; then
  none "unreadable: malformed evals-metric annotation on $where: ${msg:0:80}"
fi
p="${BASH_REMATCH[1]}" t="${BASH_REMATCH[2]}"
[ "$p" -le "$t" ] || none "unreadable: evals-metric says passed=$p > total=$t on $where"
[ "$t" -ge 1 ] || none "unreadable: evals-metric says total=0 (no script evals) on $where"
# Setup code before run.sh can print a forged notice and then fail, or make run.sh stop before
# its own: the conclusion catches a forged P == T and a forged P < T on a passing run.
want=failure
[ "$p" -lt "$t" ] || want=success
[ "$conclusion" = "$want" ] \
  || none "unreadable: metric disagrees with run conclusion on $where: passed=$p total=$t"
echo "metric: {\"passed\":$p,\"total\":$t}"
echo "rate: $p/$t"
echo "source: $where: $p/$t evals pass"
