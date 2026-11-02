#!/usr/bin/env bash
# autopilot.sh — offline tests for the helpers behind autopilot's run ledger.
#
# Usage:
#   bash scripts/test/autopilot.sh
#
#   - octo-evals-metric.sh : the evals metric read, against a stub `gh` that runs the helper's
#                            --jq filters with jq: no evals.yml on the default branch, a metric
#                            read across the run's jobs (beside other annotations, on a default
#                            branch not named main), P == T, no completed run (none listed, or
#                            the workflow unknown to GitHub), no annotation, two (ambiguous), a
#                            title that only nearly matches, malformed messages (leading zero,
#                            extra space, trailing text, a newline, not a number), P > T, T = 0,
#                            and gh errors, each printing `metric: null` with the reason and
#                            exiting 0
#   - octo-ledger-state.sh : the convergence decision against a stub ledger: the merge rule
#                            without a metric, the P-gain rule (an idle merge is no gain, P rising
#                            is one without a merge, P falling or T rising is not, a metric on
#                            one side only falls back to merges, observe entries never gain), the
#                            walk stopping at a reset or an all-pass entry, the all-pass decision
#                            first (over a converged ledger, and with --resume), --resume, no
#                            ledger yet, the validity rules (author association, a malformed or
#                            incomplete entry, an unknown kind, two blocks, a non-numeric metric),
#                            a gh error, and bad arguments
#
# Nothing here calls the real gh or the network. Exits 0 when every check passes, 1 when any fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
METRIC="$SCRIPTS_DIR/octo-evals-metric.sh"
STATE="$SCRIPTS_DIR/octo-ledger-state.sh"
# Neither helper reads it, but pin it so nothing here depends on running under Actions or not.
export GITHUB_ACTIONS=false

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ✓ $1"; }
no() { fail=$((fail + 1)); echo "  ✗ $1"; }
# same <label> <wanted> <got> : the two strings are equal.
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    no "$1"; printf '      wanted: %s\n      got:    %s\n' "$2" "$3"; fi
}
# bounded <seconds> <command...> : SIGALRM-kill a hung command (macOS has no `timeout`).
bounded() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }

command -v jq >/dev/null || { echo "autopilot: jq is required for the stub gh" >&2; exit 1; }
# No `set -e`: bail out explicitly, or an empty $tmp would point the stub at the real checkout.
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "autopilot: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# A stub `gh` first on PATH answers from JSON files in $ST_DIR through the helper's own --jq
# filter (jq -r): `repo view` → repo.json, contents → a file or, with $ST_NOWF, gh's 404, a
# workflow's runs → runs.json (or a 404 with $ST_NORUNS; it checks the branch and status
# parameters), a run's jobs → jobs-<run>.json, annotations → ann-<id>.json (or none), and
# `issue view` → ledger.json. $ST_FAIL=<endpoint word> makes that call fail with a 500.
stub="$tmp/bin"
ST_DIR="$tmp/st"
mkdir -p "$stub" "$ST_DIR"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift; ep="" jq="" params=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;; --jq) jq="$2"; shift 2 ;; --repo | --json | -X) shift 2 ;;
    -f) params="$params $2"; shift 2 ;;
    *) ep="${ep:-$1}"; shift ;;
  esac
done
fail() { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
case "$cmd" in
  repo) [ "${ST_FAIL:-}" != repo ] || fail; f="$ST_DIR/repo.json" ;;
  issue) [ "${ST_FAIL:-}" != issue ] || fail; f="$ST_DIR/ledger.json" ;;
  api)
    case "$ep" in
      */contents/.github/workflows/evals.yml)
        [ "${ST_FAIL:-}" != contents ] || fail
        [ -z "${ST_NOWF:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        case "$params" in *" ref=$ST_BRANCH"*) ;; *) echo "stub: bad ref:$params" >&2; exit 9 ;; esac
        echo file; exit 0 ;;
      */actions/workflows/evals.yml/runs)
        [ "${ST_FAIL:-}" != runs ] || fail
        [ -z "${ST_NORUNS:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        case "$params" in *" branch=$ST_BRANCH "*"status=completed"*) ;;
          *) echo "stub: bad params:$params" >&2; exit 9 ;; esac
        f="$ST_DIR/runs.json" ;;
      */actions/runs/*/jobs*) [ "${ST_FAIL:-}" != jobs ] || fail
        f="${ep%/jobs*}"; f="$ST_DIR/jobs-${f##*/}.json" ;;
      */check-runs/*/annotations*) [ "${ST_FAIL:-}" != annotations ] || fail
        f="${ep%/annotations*}"; f="$ST_DIR/ann-${f##*/}.json"
        [ -f "$f" ] || { echo '[]' | jq -r "$jq"; exit; } ;;
      *) echo "stub: unexpected endpoint $ep" >&2; exit 9 ;;
    esac ;;
  *) echo "stub: unexpected command $cmd" >&2; exit 9 ;;
esac
jq -r "$jq" "$f"
STUB
chmod +x "$stub/gh"
export ST_DIR ST_BRANCH=trunk

echo "• octo-evals-metric.sh (offline, stub gh)"
printf '{"defaultBranchRef":{"name":"trunk"}}\n' >"$ST_DIR/repo.json"
URL=https://github.com/o/n/actions/runs/77
# runs <id conclusion>? : the latest completed run, or none.
runs() {
  if [ $# -eq 0 ]; then echo '{"total_count":0,"workflow_runs":[]}' >"$ST_DIR/runs.json"; return; fi
  printf '{"total_count":1,"workflow_runs":[{"id":%s,"conclusion":"%s","html_url":"%s"}]}\n' \
    "$1" "$2" "https://github.com/o/n/actions/runs/$1" >"$ST_DIR/runs.json"
}
# jobs <run> <check-run id>... : that run's jobs.
jobs() {
  local run="$1" sep="" body="" id; shift
  for id in "$@"; do
    body="$body$sep{\"name\":\"evals\",\"check_run_url\":\"https://api.github.com/repos/o/n/check-runs/$id\"}"
    sep=","
  done
  printf '{"total_count":0,"jobs":[%s]}\n' "$body" >"$ST_DIR/jobs-$run.json"
}
# ann <check-run id> <json array> : that check run's annotations.
ann() { printf '%s\n' "$2" >"$ST_DIR/ann-$1.json"; }
# metric : run the helper; sets out / rc.
metric() {
  out="$(PATH="$stub:$PATH" bounded 10 bash "$METRIC" --repo o/n 2>/dev/null)"
  rc=$?
}
# reads <label> <source line> : the helper exited 0 with no metric and that source.
reads_null() { same "$1" "0|metric: null|source: $2" "$rc|$(printf '%s' "$out" | paste -sd '|' -)"; }

ST_NOWF=1 metric
reads_null "no evals.yml on the default branch: no evals workflow" "no evals workflow"
runs 77 failure
jobs 77 501 502
ann 501 '[{"title":"other","message":"x"},{"title":"evals-metric","message":"passed=4 total=6"}]'
ann 502 '[{"title":"evals-guard-base","message":"abc"}]'
metric
same "a failing run's metric, read across its jobs beside other annotations" \
  "0|metric: {\"passed\":4,\"total\":6}|source: run 77 (failure) $URL: 4/6 evals pass" \
  "$rc|$(printf '%s' "$out" | paste -sd '|' -)"
runs 78 success
jobs 78 503
ann 503 '[{"title":"evals-metric","message":"passed=5 total=5"}]'
metric
same "every eval passing: P == T" \
  "0|metric: {\"passed\":5,\"total\":5}|source: run 78 (success) https://github.com/o/n/actions/runs/78: 5/5 evals pass" \
  "$rc|$(printf '%s' "$out" | paste -sd '|' -)"
runs
metric
reads_null "no completed run on the default branch" "unreadable: no completed evals.yml run on trunk"
ST_NORUNS=1 metric
reads_null "a workflow GitHub never registered (404): no completed run" \
  "unreadable: no completed evals.yml run on trunk"
runs 77 cancelled
ann 501 '[{"title":"other","message":"passed=4 total=6"}]'
ann 502 '[]'
metric
reads_null "a run with no evals-metric annotation" \
  "unreadable: no evals-metric annotation on run 77 (cancelled) $URL"
runs 77 failure
ann 501 '[{"title":"evals-metric ","message":"passed=4 total=6"},{"title":"Evals-metric","message":"passed=4 total=6"}]'
metric
reads_null "titles that only nearly match are not the metric" \
  "unreadable: no evals-metric annotation on run 77 (failure) $URL"
ann 501 '[{"title":"evals-metric","message":"passed=4 total=6"}]'
ann 502 '[{"title":"evals-metric","message":"passed=6 total=6"}]'
metric
reads_null "two evals-metric annotations (one per job): ambiguous" \
  "unreadable: 2 evals-metric annotations on run 77 (failure) $URL (ambiguous)"
ann 502 '[]'
for bad in 'passed=04 total=6' 'passed=4  total=6' 'passed=4 total=6 ' 'passed=4 total=six' \
    'passed=-1 total=6' 'passed=4 total=6 passed=6' 'passed=1234567890 total=1234567890'; do
  ann 501 "[{\"title\":\"evals-metric\",\"message\":\"$bad\"}]"
  metric
  reads_null "a malformed message ($bad)" \
    "unreadable: malformed evals-metric annotation on run 77 (failure) $URL: \"$bad\""
done
ann 501 '[{"title":"evals-metric","message":"passed=4 total=6\npassed=6 total=6"}]'
metric
reads_null "a message holding a newline counts once, as malformed" \
  "unreadable: malformed evals-metric annotation on run 77 (failure) $URL: \"passed=4 total=6\\npassed=6 total=6\""
ann 501 '[{"title":"evals-metric","message":"passed=7 total=6"}]'
metric
reads_null "P > T" "unreadable: evals-metric says passed=7 > total=6 on run 77 (failure) $URL"
ann 501 '[{"title":"evals-metric","message":"passed=0 total=0"}]'
metric
reads_null "T = 0 (no script evals)" \
  "unreadable: evals-metric says total=0 (no script evals) on run 77 (failure) $URL"
ann 501 '[{"title":"evals-metric","message":"passed=4 total=6"}]'
for step in repo contents runs jobs annotations; do
  ST_FAIL=$step metric
  reads_null "a gh error reading $step: no metric, exit 0" \
    "unreadable: gh error: gh: Server Error (HTTP 500)"
done
out="$(bash "$METRIC" 2>/dev/null)"; rc=$?
same "no --repo exits 2" "2|" "$rc|$out"

echo "• octo-ledger-state.sh (offline, stub gh)"
# e <kind> <merged> <metric json> : one entry's JSON.
e() {
  printf '{"time": "2026-11-01T09:30:00Z", "mode": "semi", "cycles_used": 1, "merged": %s, "held": 0, "proposals_filed": 0, "metric": %s, "cost_usd": null, "kind": "%s"}' \
    "$2" "$3" "$1"
}
# ledger <assoc|body>... : write the ledger's comments, oldest first. Each argument is
# "<authorAssociation>|<entry json>", posted in the recipe's shape, or "<assoc>|=<raw body>".
ledger() {
  local sep="" body="" a b
  for a in "$@"; do
    b="${a#*|}"
    case "$b" in
      =*) b="${b#=}" ;;
      *) b="$(printf 'Autopilot run (semi): merged nothing.\n\n```json\n%s\n```' "$b")" ;;
    esac
    body="$body$sep$(jq -n --arg a "${a%%|*}" --arg b "$b" '{authorAssociation: $a, body: $b}')"
    sep=","
  done
  printf '{"comments":[%s]}\n' "$body" >"$ST_DIR/ledger.json"
}
# state <args...> : run the helper on ledger #9 with --runs 3 unless given; sets out / rc.
state() {
  out="$(PATH="$stub:$PATH" bounded 10 bash "$STATE" --repo o/n --issue 9 --runs 3 "$@" \
    2>/dev/null)"
  rc=$?
  out="$(printf '%s' "$out" | paste -sd '|' -)"
}
# decides <label> <entries> <skipped> <streak> <decision> : the helper exited 0 with these lines.
decides() {
  same "$1" "0|entries: $2|skipped: $3|streak: $4|decision: $5" "$rc|$out"
}
O=OWNER
m() { printf '{"passed": %s, "total": %s}' "$1" "$2"; }

ledger "$O|$(e run 0 null)" "$O|$(e run 0 null)" "$O|$(e run 0 null)"
state
decides "no metric: three runs without a merge converge" "3 (all)" none 3/3 observe
ledger "$O|$(e run 0 null)" "$O|$(e run 0 null)" "$O|$(e run 1 null)"
state
decides "no metric: a merge is a gain" "3 (all)" none 0/3 build
ledger "$O|$(e run 0 null)" "$O|$(e run 1 null)" "$O|$(e run 0 null)" "$O|$(e run 0 null)"
state
decides "no metric: the streak counts back to the last merge" "4 (all)" none 2/3 build
ledger "$O|$(e run 1 null)" "$O|$(e run 0 null)"
state
decides "fewer than N entries: not converged" "2 (all)" none 1/3 build

# P-gain: both entries have a numeric metric.
ledger "$O|$(e run 0 "$(m 2 6)")" "$O|$(e run 1 "$(m 2 6)")" "$O|$(e run 1 "$(m 2 6)")" \
  "$O|$(e run 1 "$(m 2 6)")"
state --metric 2/6
decides "P-gain: merges that move no eval are no gain, and converge" "4 (all)" none 4/3 observe
ledger "$O|$(e run 0 "$(m 2 6)")" "$O|$(e run 0 "$(m 3 6)")" "$O|$(e run 0 "$(m 3 6)")" \
  "$O|$(e run 0 "$(m 3 6)")"
state --metric 3/6
decides "P-gain: P rising is a gain without a merge" "4 (all)" none 2/3 build
ledger "$O|$(e run 0 "$(m 4 6)")" "$O|$(e run 1 "$(m 3 6)")" "$O|$(e run 1 "$(m 3 6)")" \
  "$O|$(e run 1 "$(m 3 6)")"
state --metric 3/6
decides "P-gain: P falling (a regression) is no gain" "4 (all)" none 4/3 observe
ledger "$O|$(e run 0 "$(m 4 6)")" "$O|$(e run 1 "$(m 4 8)")" "$O|$(e run 1 "$(m 4 8)")" \
  "$O|$(e run 1 "$(m 4 8)")"
state --metric 4/8
decides "P-gain: T rising (new must-fail evals) with P unchanged is no gain" "4 (all)" none 4/3 \
  observe
ledger "$O|$(e run 0 null)" "$O|$(e run 1 "$(m 4 6)")" "$O|$(e run 0 "$(m 4 6)")" \
  "$O|$(e run 0 "$(m 4 6)")"
state
decides "a metric on one side only: the merge rule decides that entry" "4 (all)" none 2/3 build
ledger "$O|$(e run 0 "$(m 2 6)")" "$O|$(e observe 0 "$(m 3 6)")" "$O|$(e observe 0 "$(m 4 6)")" \
  "$O|$(e observe 0 "$(m 5 6)")"
state --metric 5/6
decides "observe entries never gain, even when P rose" "4 (all)" none 4/3 observe

# Where the walk stops.
ledger "$O|$(e run 0 null)" "$O|$(e run 0 null)" "$O|$(e run 0 null)" "$O|$(e reset 0 null)" \
  "$O|$(e run 0 null)" "$O|$(e run 0 null)"
state
decides "the walk stops at the last reset" "2 (since the last reset)" none 2/3 build
ledger "$O|$(e reset 0 "$(m 4 6)")" "$O|$(e run 0 "$(m 5 6)")"
state --metric 5/6
decides "a reset entry's metric is the baseline for the entry after it" \
  "1 (since the last reset)" none 0/3 build
ledger "$O|$(e run 0 "$(m 2 6)")" "$O|$(e run 0 "$(m 2 6)")" "$O|$(e observe 0 "$(m 5 5)")" \
  "$O|$(e observe 0 "$(m 5 5)")" "$O|$(e run 1 "$(m 5 8)")" "$O|$(e run 0 "$(m 5 8)")"
state --metric 5/8
decides "the walk stops at an all-pass entry: a new milestone starts the count again" \
  "2 (since the last all-pass entry)" none 2/3 build

# The decision.
ledger "$O|$(e observe 0 "$(m 4 6)")" "$O|$(e observe 0 "$(m 4 6)")" \
  "$O|$(e observe 0 "$(m 4 6)")"
state --metric 6/6
decides "P == T over a converged ledger: all-pass" "3 (all)" none 3/3 all-pass
state --metric 4/6
decides "the same ledger, P < T: observe" "3 (all)" none 3/3 observe
state --metric 4/6 --resume
decides "--resume: the walk is empty, so build" "0 (since --resume)" none 0/3 build
state --metric 6/6 --resume
decides "--resume with P == T: all-pass" "0 (since --resume)" none 0/3 all-pass
state --metric none --runs 2
decides "--runs sets N" "3 (all)" none 3/2 observe
# nolog <args...> : run the helper with no --issue; sets out / rc.
nolog() {
  out="$(PATH="$stub:$PATH" bounded 10 bash "$STATE" --repo o/n --runs 3 "$@" 2>/dev/null)"
  rc=$?
  out="$(printf '%s' "$out" | paste -sd '|' -)"
}
nolog
decides "no ledger yet: build" "0 (no ledger yet)" none 0/3 build
nolog --metric 2/2
decides "no ledger yet, P == T: all-pass" "0 (no ledger yet)" none 0/3 all-pass

# Validity: only an allowed author's well-formed entry counts.
ledger "$O|$(e run 0 null)" "MEMBER|$(e run 0 null)" "COLLABORATOR|$(e run 0 null)" \
  "CONTRIBUTOR|$(e run 1 null)" "NONE|$(e run 1 null)" "NONE|$(e run 1 null)" \
  "$O|=just talking about runs"
state
decides "other authors' entries are skipped and counted" "3 (all)" "1 (CONTRIBUTOR), 2 (NONE)" 3/3 \
  observe
eight="$(e run 1 null | jq -c 'del(.cost_usd)')"
ledger "$O|$(e run 0 null)" "$O|$(e run 0 null)" "$O|$(e run 0 null)" "$O|$eight" \
  "$O|$(e retry 1 null)" "$O|={\"merged\": 1} \`\`\`json not json \`\`\`" \
  "$O|=two blocks
\`\`\`json
$(e run 1 null)
\`\`\`
\`\`\`json
$(e run 1 null)
\`\`\`"
state
decides "a missing key, an unknown kind, bad JSON, and two blocks are not entries" "3 (all)" none \
  3/3 observe
# Each would be no gain if read as P=3 against the previous 4/6; as no metric, the merge counts.
for bad in "$(m 3 2)" "$(m 3.5 6)" '"3/6"' '{"passed": "3", "total": "6"}' "$(m 3 0)"; do
  ledger "$O|$(e run 0 "$(m 4 6)")" "$O|$(e run 1 "$bad")"
  state
  decides "a metric that is not valid ($bad) falls back to the merge rule" "2 (all)" none 0/3 build
done
ledger "$O|$(e run 0 "$(m 5 5)")" "$O|$(e run 0 '{"passed": 3, "total": 3, "x": 1}')"
state
decides "an all-pass entry with extra metric keys still ends the walk" \
  "0 (since the last all-pass entry)" none 0/3 build
ST_FAIL=issue state
same "a gh error reading the ledger exits 3" "3|" "$rc|$out"
for bad in "--runs 0" "--runs x" "--metric 7/6" "--metric 0/0" "--metric 04/6" "--metric 4" \
    "--issue x"; do
  # shellcheck disable=SC2086 # each case is two words on purpose
  out="$(bash "$STATE" --repo o/n --runs 3 $bad 2>/dev/null)"; rc=$?
  same "bad argument $bad exits 2" "2|" "$rc|$out"
done

echo
echo "autopilot: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
