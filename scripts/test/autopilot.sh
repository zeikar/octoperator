#!/usr/bin/env bash
# autopilot.sh — offline tests for the helpers behind autopilot's run ledger, its P == T
# decision, and its web access.
#
# Usage:
#   bash scripts/test/autopilot.sh
#
#   - octo-evals-metric.sh : the evals metric read, against a stub `gh` that runs the helper's
#                            --jq filters with jq: no evals.yml on the default branch, a metric
#                            read across the run's jobs (beside other annotations, on a default
#                            branch not named main), P == T, a dispatch run, the run filter
#                            (a fork's pull_request run, or a push from another repo, on the
#                            branch is skipped for an older matching run), no completed run (none
#                            listed, none matching, or the workflow unknown to GitHub), no
#                            annotation, two (ambiguous), a title that only nearly matches, a
#                            level other than notice, malformed messages (leading zero, extra
#                            space, trailing text, a newline, not a number), P > T, T = 0, a
#                            conclusion that disagrees (a forged P == T on a failed run, a forged
#                            P < T on a passing one, a cancelled run), and gh errors, each
#                            printing `metric: null` and `rate: none` with the reason and exiting 0
#                            (`head:` is the run's head commit, or `none` with no metric)
#   - octo-ledger-state.sh : the convergence decision against a stub ledger: the merge rule
#                            without a metric, the P-gain rule (an idle merge is no gain, P rising
#                            is one without a merge, P falling or T rising is not, no numeric
#                            entry before it falls back to merges, observe entries never gain),
#                            the high-water mark and its line (P oscillating converges, strictly
#                            rising never does, a recovery to the old high is no gain, observe
#                            entries' P counts, the mark restarts at a reset or all-pass entry
#                            from its P, a null reset leaves the first numeric entry to merges,
#                            null entries don't hide it, other authors' entries don't raise it),
#                            the walk stopping at a reset or an all-pass entry, the all-pass line
#                            beside the ledger's own decision (over a converged ledger, and with
#                            --resume), --resume, no
#                            ledger yet, the validity rules (author association, a malformed or
#                            incomplete entry, an unknown kind, two blocks, a non-numeric metric),
#                            the planning-failed line (the newest run entry's planning_failed,
#                            past observe entries; none after a reset, a newer run, with
#                            --resume, or when malformed; its reason on one line, cut at 80),
#                            a gh error, and bad arguments, its comments read across pages
#   - octo-milestone-gate.sh : autopilot's P == T decision (and genesis --next's guards):
#                            buildable work wins over everything without a gh call, then an
#                            open next-milestone PR (the lowest of two, across pages; a fork's
#                            or a deleted fork's milestone-* branch and other branches don't
#                            count), then P < T or no metric,
#                            then planning that failed at the tip, then the newest closed
#                            milestone PR declined at the tip: the tip is the merge base (no
#                            date read), or the tip's committer date is at or before closedAt
#                            (work merged while it was open; also when the compare 404s), not
#                            once the tip moved after the close (a compare 404 then plans), a
#                            newer one merged, a fork's or another branch's PR, or with
#                            --resume; a malformed date or closedAt exits 3; then
#                            a metric run on an older commit than the tip: `stale wait` while a
#                            push or dispatch run of evals.yml for the tip is queued or running,
#                            else `stale dispatch` (completed, pull_request, and fork runs don't
#                            count), else plan; gh errors exit 3, bad arguments 2
#   - octo-web-allowed.sh  : the settings check for autopilot's web access, against throwaway
#                            settings files (the repo's two and a stand-in $HOME's): both bare
#                            allows across files pass; none, one, or only a scoped allow fail; a
#                            deny or ask naming a tool, bare or scoped, in any file wins; one
#                            naming another tool doesn't; invalid JSON or the wrong shape allows
#                            nothing; bad arguments exit 2
#
# The stub gh serves REST only and refuses GraphQL and porcelain with the Claude Code cloud
# proxy's 403, and no helper call is refused. REST has no isEmpty, so an empty repo is covered
# too: its default_branch still reads, its contents 404 (no evals workflow), and its tip 409s
# (the gate exits 3). Nothing here calls the real gh or the network. Exits 0 when every check
# passes, 1 when any fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
METRIC="$SCRIPTS_DIR/octo-evals-metric.sh"
STATE="$SCRIPTS_DIR/octo-ledger-state.sh"
GATE="$SCRIPTS_DIR/octo-milestone-gate.sh"
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
# bounded <seconds> <command...> : SIGALRM-kill a hung command (macOS has no `timeout`). A kill
# exits 142 and says so on fd 9, the suite's own stderr, so no caller's 2>/dev/null hides it and a
# slow run reads as a timeout, not as a wrong result.
exec 9>&2
bounded() {
  perl -e '$t = shift; alarm $t; exec @ARGV or exit 127' "$@" 9>&-; set -- "$?" "$@"
  [ "$1" -ne 142 ] || echo "  ! TIMEOUT: killed after $2s: ${*:3}" >&9
  return "$1"
}

command -v jq >/dev/null || { echo "autopilot: jq is required for the stub gh" >&2; exit 1; }
# No `set -e`: bail out explicitly, or an empty $tmp would point the stub at the real checkout.
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "autopilot: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# A stub `gh` first on PATH serves REST only, like a Claude Code cloud session: anything but
# `gh api repos/...` (porcelain, `gh api graphql`) gets the cloud proxy's 403 and is logged to
# $ST_DIR/rejected. It answers from JSON files in $ST_DIR through the helper's own --jq filter
# (jq -r): the repo → repo.json, contents → a file or, with $ST_NOWF, gh's 404 (with $ST_EMPTY,
# the 404 an empty repo gives), a workflow's runs → runs.json (or a 404 with $ST_NORUNS; it
# checks the branch and status parameters), a run's jobs → jobs-<run>.json, annotations →
# ann-<id>.json (or none), the ledger's comments → ledger.json, the open pull requests →
# prs.json, the newest closed ones → prs-closed.json (`[]` when missing), a branch's ref →
# ref.json (it checks the branch; with $ST_EMPTY, the 409 an empty repo gives), a compare →
# compare.json (or gh's 404 with $ST_CMP404), the tip's commit → commit.json (it checks the
# commit), and the runs for one head commit → runs-tip.json (it checks the parameters). A list
# the helper reads with --paginate (the comments, the open pull requests) is served two items a
# page, running the filter once per page, as gh does; the closed list, read without it, is one
# page, standing in for GitHub's 100.
# $ST_FAIL=<endpoint word> makes that call fail with a 500 (pr-open and pr-closed for the lists).
stub="$tmp/bin"
ST_DIR="$tmp/st"
mkdir -p "$stub" "$ST_DIR"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
call=$(printf '%s' "$*" | tr '\n' ' ')
reject() {
  echo "$call" >>"$ST_DIR/rejected"
  echo 'gh: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). (HTTP 403)' >&2
  exit 1
}
[ "${1:-}" = api ] || reject
shift; ep="" jq="." params="" paginate=0
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paginate=1; shift ;; --jq) jq="$2"; shift 2 ;; -X) shift 2 ;;
    -f) params="$params $2"; shift 2 ;;
    -*) echo "stub: unknown flag $1" >&2; exit 9 ;;
    *) ep="${ep:-$1}"; shift ;;
  esac
done
[ "$ep" != graphql ] || reject
fail() { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
# pages <file> : the JSON array in <file>, two items a page, the filter run on each.
pages() {
  local n i=0
  [ "$paginate" -eq 1 ] || { echo "stub: $ep without --paginate" >&2; exit 9; }
  n=$(jq length "$1")
  while [ "$i" -lt "$n" ]; do jq -c ".[$i:$((i + 2))]" "$1" | jq -r "$jq" || exit 9; i=$((i + 2)); done
  exit 0
}
case "$ep" in
  repos/o/n) [ "${ST_FAIL:-}" != repo ] || fail; f="$ST_DIR/repo.json" ;;
  "repos/o/n/issues/9/comments?per_page=100")
    [ "${ST_FAIL:-}" != issue ] || fail; pages "$ST_DIR/ledger.json" ;;
  "repos/o/n/pulls?state=open&per_page=100")
    [ "${ST_FAIL:-}" != pr-open ] || fail; pages "$ST_DIR/prs.json" ;;
  "repos/o/n/pulls?state=closed&sort=created&direction=desc&per_page=100")
    [ "${ST_FAIL:-}" != pr-closed ] || fail
    [ "$paginate" -eq 0 ] || { echo "stub: one page wanted" >&2; exit 9; }
    f="$ST_DIR/prs-closed.json"; [ -f "$f" ] || { echo '[]' | jq -r "$jq"; exit; } ;;
  repos/o/n/*)
    case "$ep" in
      */contents/.github/workflows/evals.yml)
        [ "${ST_FAIL:-}" != contents ] || fail
        [ -z "${ST_NOWF:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        [ -z "${ST_EMPTY:-}" ] || { echo "gh: This repository is empty. (HTTP 404)" >&2; exit 1; }
        case "$params" in *" ref=$ST_BRANCH"*) ;; *) echo "stub: bad ref:$params" >&2; exit 9 ;; esac
        echo file; exit 0 ;;
      */actions/workflows/evals.yml/runs)
        case "$params" in *" head_sha="*)
          [ "${ST_FAIL:-}" != tipruns ] || fail
          case "$params" in *" branch=$ST_BRANCH head_sha=$ST_TIP per_page=20") ;;
            *) echo "stub: bad params:$params" >&2; exit 9 ;; esac
          jq -r "$jq" "$ST_DIR/runs-tip.json"; exit ;;
        esac
        [ "${ST_FAIL:-}" != runs ] || fail
        [ -z "${ST_NORUNS:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        case "$params" in *" branch=$ST_BRANCH "*"status=completed per_page=20"*) ;;
          *) echo "stub: bad params:$params" >&2; exit 9 ;; esac
        f="$ST_DIR/runs.json" ;;
      */actions/runs/*/jobs*) [ "${ST_FAIL:-}" != jobs ] || fail
        f="${ep%/jobs*}"; f="$ST_DIR/jobs-${f##*/}.json" ;;
      */git/ref/heads/*) [ "${ST_FAIL:-}" != ref ] || fail
        [ "$ep" = "repos/o/n/git/ref/heads/$ST_BRANCH" ] || { echo "stub: bad ref $ep" >&2; exit 9; }
        [ -z "${ST_EMPTY:-}" ] || { echo "gh: Git Repository is empty. (HTTP 409)" >&2; exit 1; }
        f="$ST_DIR/ref.json" ;;
      */compare/*) [ "${ST_FAIL:-}" != compare ] || fail
        [ "$ep" = "repos/o/n/compare/$ST_TIP...$ST_CMP_HEAD" ] || { echo "stub: bad compare $ep" >&2; exit 9; }
        [ -z "${ST_CMP404:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        f="$ST_DIR/compare.json" ;;
      */git/commits/*) [ "${ST_FAIL:-}" != commit ] || fail
        [ "$ep" = "repos/o/n/git/commits/$ST_TIP" ] || { echo "stub: bad commit $ep" >&2; exit 9; }
        f="$ST_DIR/commit.json" ;;
      */check-runs/*/annotations*) [ "${ST_FAIL:-}" != annotations ] || fail
        f="${ep%/annotations*}"; f="$ST_DIR/ann-${f##*/}.json"
        [ -f "$f" ] || { echo '[]' | jq -r "$jq"; exit; } ;;
      *) echo "stub: unexpected endpoint $ep" >&2; exit 9 ;;
    esac ;;
  *) echo "stub: unexpected endpoint $ep" >&2; exit 9 ;;
esac
jq -r "$jq" "$f"
STUB
chmod +x "$stub/gh"
export ST_DIR ST_BRANCH=trunk

echo "• octo-evals-metric.sh (offline, stub gh)"
# REST's default_branch (GraphQL's defaultBranchRef.name).
printf '{"full_name":"o/n","default_branch":"trunk"}\n' >"$ST_DIR/repo.json"
URL=https://github.com/o/n/actions/runs/77
# sha <n> : a 40-digit commit for <n>, the head of run <n>.
sha() { printf '%040d' "$1"; }
# runs [<id>:<conclusion>[:<event>[:<head repo>]]]... : the completed runs, newest first (event
# push and head repo o/n unless given), or none. Run <id>'s head commit is $(sha <id>).
runs() {
  local sep="" body="" r id c ev hr
  for r in "$@"; do
    IFS=: read -r id c ev hr <<<"$r"
    body="$body$sep$(printf '{"id":%s,"conclusion":"%s","html_url":"%s","event":"%s",%s,%s}' \
      "$id" "$c" "https://github.com/o/n/actions/runs/$id" "${ev:-push}" \
      "\"head_repository\":{\"full_name\":\"${hr:-o/n}\"}" "\"head_sha\":\"$(sha "$id")\"")"
    sep=","
  done
  printf '{"total_count":%s,"workflow_runs":[%s]}\n' "$#" "$body" >"$ST_DIR/runs.json"
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
# reads_null <label> <source line> : the helper exited 0 with no metric and that source.
reads_null() {
  same "$1" "0|metric: null|rate: none|source: $2|head: none" \
    "$rc|$(printf '%s' "$out" | paste -sd '|' -)"
}
# reads <label> <P> <T> <run id> <conclusion> : the helper exited 0 with that metric.
reads() {
  same "$1" \
    "0|metric: {\"passed\":$2,\"total\":$3}|rate: $2/$3|source: run $4 ($5) https://github.com/o/n/actions/runs/$4: $2/$3 evals pass|head: $(sha "$4")" \
    "$rc|$(printf '%s' "$out" | paste -sd '|' -)"
}

ST_NOWF=1 metric
reads_null "no evals.yml on the default branch: no evals workflow" "no evals workflow"
# REST has no isEmpty, and an empty repo still has a default_branch (GraphQL's defaultBranchRef
# was null): the workflow file's read 404s, so it reads as no workflow.
ST_EMPTY=1 metric
reads_null "an empty repo (its contents 404): no evals workflow" "no evals workflow"
# notice <title> <message> : one notice annotation's JSON.
notice() { printf '{"annotation_level":"notice","title":"%s","message":"%s"}' "$1" "$2"; }
runs 77:failure
jobs 77 501 502
ann 501 "[$(notice other x),$(notice evals-metric 'passed=4 total=6')]"
ann 502 "[$(notice evals-guard-base abc)]"
metric
reads "a failing run's metric, read across its jobs beside other annotations" 4 6 77 failure
runs 78:success
jobs 78 503
ann 503 "[$(notice evals-metric 'passed=5 total=5')]"
metric
reads "every eval passing: P == T" 5 5 78 success
runs 78:success:workflow_dispatch
metric
reads "a workflow_dispatch run counts" 5 5 78 success
runs 79:failure:pull_request:fork/n 80:success:push:fork/n 78:success
jobs 79 504
ann 504 "[$(notice evals-metric 'passed=6 total=6')]"
metric
reads "a fork's pull_request run and another repo's push on the branch are skipped" 5 5 78 success
runs 78:success:push:O/N
metric
reads "the head repository compares case-insensitively" 5 5 78 success
NOMATCH="unreadable: no completed push or dispatch run of evals.yml on trunk (newest 20 checked)"
runs 79:failure:pull_request:fork/n 81:success:schedule
metric
reads_null "only runs the filter skips: no completed run" "$NOMATCH"
runs
metric
reads_null "no completed run on the default branch" "$NOMATCH"
ST_NORUNS=1 metric
reads_null "a workflow GitHub never registered (404): no completed run" "$NOMATCH"
runs 77:cancelled
ann 501 "[$(notice other 'passed=4 total=6')]"
ann 502 '[]'
metric
reads_null "a run with no evals-metric annotation" \
  "unreadable: no evals-metric annotation on run 77 (cancelled) $URL"
runs 77:failure
ann 501 "[$(notice 'evals-metric ' 'passed=4 total=6'),$(notice Evals-metric 'passed=4 total=6')]"
metric
reads_null "titles that only nearly match are not the metric" \
  "unreadable: no evals-metric annotation on run 77 (failure) $URL"
ann 501 '[{"annotation_level":"warning","title":"evals-metric","message":"passed=4 total=6"}]'
metric
reads_null "an evals-metric annotation that is not a notice is not the metric" \
  "unreadable: no evals-metric annotation on run 77 (failure) $URL"
ann 501 "[$(notice evals-metric 'passed=6 total=6')]"
metric
reads_null "a forged P == T on a failed run (run.sh never printed): disagrees" \
  "unreadable: metric disagrees with run conclusion on run 77 (failure) $URL: passed=6 total=6"
runs 77:success
ann 501 "[$(notice evals-metric 'passed=4 total=6')]"
metric
reads_null "a forged P < T on a passing run: disagrees" \
  "unreadable: metric disagrees with run conclusion on run 77 (success) $URL: passed=4 total=6"
runs 77:cancelled
metric
reads_null "a cancelled run's metric is not trusted" \
  "unreadable: metric disagrees with run conclusion on run 77 (cancelled) $URL: passed=4 total=6"
runs 77:failure
ann 501 "[$(notice evals-metric 'passed=4 total=6')]"
ann 502 "[$(notice evals-metric 'passed=6 total=6')]"
metric
reads_null "two evals-metric annotations (one per job): ambiguous" \
  "unreadable: 2 evals-metric annotations on run 77 (failure) $URL (ambiguous)"
ann 502 '[]'
for bad in 'passed=04 total=6' 'passed=4  total=6' 'passed=4 total=6 ' 'passed=4 total=six' \
    'passed=-1 total=6' 'passed=4 total=6 passed=6' 'passed=1234567890 total=1234567890'; do
  ann 501 "[$(notice evals-metric "$bad")]"
  metric
  reads_null "a malformed message ($bad)" \
    "unreadable: malformed evals-metric annotation on run 77 (failure) $URL: \"$bad\""
done
ann 501 "[$(notice evals-metric 'passed=4 total=6\npassed=6 total=6')]"
metric
reads_null "a message holding a newline counts once, as malformed" \
  "unreadable: malformed evals-metric annotation on run 77 (failure) $URL: \"passed=4 total=6\\npassed=6 total=6\""
ann 501 "[$(notice evals-metric 'passed=7 total=6')]"
metric
reads_null "P > T" "unreadable: evals-metric says passed=7 > total=6 on run 77 (failure) $URL"
ann 501 "[$(notice evals-metric 'passed=0 total=0')]"
metric
reads_null "T = 0 (no script evals)" \
  "unreadable: evals-metric says total=0 (no script evals) on run 77 (failure) $URL"
ann 501 "[$(notice evals-metric 'passed=4 total=6')]"
for step in repo contents runs jobs annotations; do
  ST_FAIL=$step metric
  reads_null "a gh error reading $step: no metric, exit 0" \
    "unreadable: gh error: gh: Server Error (HTTP 500)"
done
runs 78:success
jobs 78 503
jq -c '.workflow_runs[0].head_sha = "abc"' "$ST_DIR/runs.json" >"$ST_DIR/r" && mv "$ST_DIR/r" "$ST_DIR/runs.json"
metric
reads_null "a run whose head commit is not 40 hex digits" \
  "unreadable: unexpected head commit on run 78"
out="$(bash "$METRIC" 2>/dev/null)"; rc=$?
same "no --repo exits 2" "2|" "$rc|$out"
out="$(bash "$METRIC" --repo 'o/n"' 2>/dev/null)"; rc=$?
same "a --repo with a quote exits 2" "2|" "$rc|$out"

echo "• octo-ledger-state.sh (offline, stub gh)"
# e <kind> <merged> <metric json> : one entry's JSON.
e() {
  printf '{"time": "2026-11-01T09:30:00Z", "mode": "semi", "cycles_used": 1, "merged": %s, "held": 0, "proposals_filed": 0, "metric": %s, "cost_usd": null, "kind": "%s"}' \
    "$2" "$3" "$1"
}
# ledger <assoc|body>... : write the ledger's comments, oldest first. Each argument is
# "<author_association>|<entry json>", posted in the recipe's shape, or "<assoc>|=<raw body>".
ledger() {
  local sep="" body="" a b
  for a in "$@"; do
    b="${a#*|}"
    case "$b" in
      =*) b="${b#=}" ;;
      *) b="$(printf 'Autopilot run (semi): merged nothing.\n\n```json\n%s\n```' "$b")" ;;
    esac
    body="$body$sep$(jq -n --arg a "${a%%|*}" --arg b "$b" '{author_association: $a, body: $b}')"
    sep=","
  done
  printf '[%s]\n' "$body" >"$ST_DIR/ledger.json"
}
# state <args...> : run the helper on ledger #9 with --runs 3 unless given; sets out / rc.
state() {
  out="$(PATH="$stub:$PATH" bounded 10 bash "$STATE" --repo o/n --issue 9 --runs 3 "$@" \
    2>/dev/null)"
  rc=$?
  out="$(printf '%s' "$out" | paste -sd '|' -)"
}
# [HW=<P>] [AP=yes] [PF=<tip reason>] decides <label> <entries> <skipped> <streak> <decision> :
# the helper exited 0 with these lines, `high-water: none` (or $HW), `all-pass: no` (or $AP), and
# `planning-failed: none` (or $PF).
decides() {
  same "$1" \
    "0|entries: $2|skipped: $3|streak: $4|high-water: ${HW:-none}|all-pass: ${AP:-no}|planning-failed: ${PF:-none}|decision: $5" \
    "$rc|$out"
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
HW=2 decides "P-gain: merges that move no eval are no gain, and converge" "4 (all)" none 4/3 observe
ledger "$O|$(e run 0 "$(m 2 6)")" "$O|$(e run 0 "$(m 3 6)")" "$O|$(e run 0 "$(m 3 6)")" \
  "$O|$(e run 0 "$(m 3 6)")"
state --metric 3/6
HW=3 decides "P-gain: P rising is a gain without a merge" "4 (all)" none 2/3 build
ledger "$O|$(e run 0 "$(m 4 6)")" "$O|$(e run 1 "$(m 3 6)")" "$O|$(e run 1 "$(m 3 6)")" \
  "$O|$(e run 1 "$(m 3 6)")"
state --metric 3/6
HW=4 decides "P-gain: P falling (a regression) is no gain" "4 (all)" none 4/3 observe
ledger "$O|$(e run 0 "$(m 4 6)")" "$O|$(e run 1 "$(m 4 8)")" "$O|$(e run 1 "$(m 4 8)")" \
  "$O|$(e run 1 "$(m 4 8)")"
state --metric 4/8
HW=4 decides "P-gain: T rising (new must-fail evals) with P unchanged is no gain" "4 (all)" none \
  4/3 observe
ledger "$O|$(e run 0 null)" "$O|$(e run 1 "$(m 4 6)")" "$O|$(e run 0 "$(m 4 6)")" \
  "$O|$(e run 0 "$(m 4 6)")"
state
HW=4 decides "no numeric entry before it: the merge rule decides that entry" "4 (all)" none 2/3 \
  build
ledger "$O|$(e run 0 "$(m 2 6)")" "$O|$(e observe 0 "$(m 3 6)")" "$O|$(e observe 0 "$(m 4 6)")" \
  "$O|$(e observe 0 "$(m 5 6)")"
state --metric 5/6
HW=5 decides "observe entries never gain, even when P rose" "4 (all)" none 4/3 observe

# The high-water mark: the highest P among the walk's older entries and the entry that ends it.
ledger "$O|$(e run 1 "$(m 4 6)")" "$O|$(e run 1 "$(m 3 6)")" "$O|$(e run 1 "$(m 4 6)")" \
  "$O|$(e run 1 "$(m 3 6)")" "$O|$(e run 1 "$(m 4 6)")"
state --metric 4/6
HW=4 decides "high-water: P oscillating 4→3→4→3→4, merging every run, converges" "5 (all)" none \
  4/3 observe
ledger "$O|$(e run 0 "$(m 1 6)")" "$O|$(e run 0 "$(m 2 6)")" "$O|$(e run 0 "$(m 3 6)")" \
  "$O|$(e run 0 "$(m 4 6)")" "$O|$(e run 0 "$(m 5 6)")"
state --metric 5/6 --runs 1
HW=5 decides "high-water: P strictly rising never converges, even with N = 1" "5 (all)" none 0/1 \
  build
ledger "$O|$(e run 0 "$(m 3 6)")" "$O|$(e run 0 "$(m 5 6)")" "$O|$(e run 1 "$(m 4 6)")" \
  "$O|$(e run 1 "$(m 5 6)")"
state --metric 5/6
HW=5 decides "high-water: recovering to the previous high is no gain" "4 (all)" none 2/3 build
ledger "$O|$(e run 0 "$(m 3 6)")" "$O|$(e run 0 "$(m 5 6)")" "$O|$(e run 1 "$(m 4 6)")" \
  "$O|$(e run 0 "$(m 6 7)")"
state --metric 6/7
HW=6 decides "high-water: passing the previous high is a gain" "4 (all)" none 0/3 build
ledger "$O|$(e run 0 "$(m 3 6)")" "$O|$(e observe 0 "$(m 5 6)")" "$O|$(e run 1 "$(m 5 6)")"
state --metric 5/6
HW=5 decides "high-water: an observe entry's P counts toward the mark" "3 (all)" none 3/3 observe
ledger "$O|$(e run 0 "$(m 6 8)")" "$O|$(e reset 0 "$(m 4 8)")" "$O|$(e run 0 "$(m 5 8)")"
state --metric 5/8
HW=5 decides "high-water: the mark restarts at a reset, from its P" "1 (since the last reset)" \
  none 0/3 build
ledger "$O|$(e run 0 "$(m 8 10)")" "$O|$(e observe 0 "$(m 6 6)")" "$O|$(e run 0 "$(m 7 9)")"
state --metric 7/9
HW=7 decides "high-water: the mark restarts at an all-pass entry, from its P" \
  "1 (since the last all-pass entry)" none 0/3 build
ledger "$O|$(e run 0 "$(m 6 8)")" "$O|$(e reset 0 null)" "$O|$(e run 0 "$(m 4 6)")"
state --metric 4/6
HW=4 decides "high-water: the first numeric entry after a null reset falls back to merges" \
  "1 (since the last reset)" none 1/3 build
ledger "$O|$(e reset 0 null)" "$O|$(e run 1 "$(m 4 6)")" "$O|$(e run 1 "$(m 4 6)")"
state --metric 4/6
HW=4 decides "high-water: ... its merge is a gain, and the next entry meets its mark" \
  "2 (since the last reset)" none 1/3 build
ledger "$O|$(e run 0 "$(m 4 6)")" "$O|$(e run 1 null)" "$O|$(e run 1 "$(m 4 6)")" \
  "$O|$(e run 0 null)" "$O|$(e run 0 null)"
state
HW=4 decides "high-water: null entries use merges, and don't hide the mark from later ones" \
  "5 (all)" none 3/3 observe
ledger "$O|$(e run 0 "$(m 4 6)")" "$O|$(e run 1 null)" "$O|$(e run 0 null)" \
  "$O|$(e run 0 "$(m 5 6)")"
state --metric 5/6
HW=5 decides "high-water: past null entries, P above the mark is a gain" "4 (all)" none 0/3 build
ledger "$O|$(e run 0 "$(m 3 6)")" "NONE|$(e run 0 "$(m 6 6)")" \
  "CONTRIBUTOR|$(e run 0 "$(m 5 6)")" "$O|$(e run 0 "$(m 4 6)")"
state --metric 4/6
HW=4 decides "high-water: other authors' entries neither end the walk nor raise the mark" \
  "2 (all)" "1 (CONTRIBUTOR), 1 (NONE)" 0/3 build

# Where the walk stops.
ledger "$O|$(e run 0 null)" "$O|$(e run 0 null)" "$O|$(e run 0 null)" "$O|$(e reset 0 null)" \
  "$O|$(e run 0 null)" "$O|$(e run 0 null)"
state
decides "the walk stops at the last reset" "2 (since the last reset)" none 2/3 build
ledger "$O|$(e reset 0 "$(m 4 6)")" "$O|$(e run 0 "$(m 5 6)")"
state --metric 5/6
HW=5 decides "a reset entry's metric is the baseline for the entry after it" \
  "1 (since the last reset)" none 0/3 build
ledger "$O|$(e run 0 "$(m 2 6)")" "$O|$(e run 0 "$(m 2 6)")" "$O|$(e observe 0 "$(m 5 5)")" \
  "$O|$(e observe 0 "$(m 5 5)")" "$O|$(e run 1 "$(m 5 8)")" "$O|$(e run 0 "$(m 5 8)")"
state --metric 5/8
HW=5 decides "the walk stops at an all-pass entry: a new milestone starts the count again" \
  "2 (since the last all-pass entry)" none 2/3 build

# The decision.
ledger "$O|$(e observe 0 "$(m 4 6)")" "$O|$(e observe 0 "$(m 4 6)")" \
  "$O|$(e observe 0 "$(m 4 6)")"
state --metric 6/6
HW=4 AP=yes decides "P == T over a converged ledger: all-pass, beside the ledger's observe" \
  "3 (all)" none 3/3 observe
state --metric 4/6
HW=4 decides "the same ledger, P < T: observe" "3 (all)" none 3/3 observe
state --metric 4/6 --resume
HW=4 decides "--resume: the walk is empty, so build" "0 (since --resume)" none 0/3 build
state --metric 6/6 --resume
HW=6 AP=yes decides "--resume with P == T: all-pass, beside build" "0 (since --resume)" none 0/3 build
state --metric none --resume
decides "--resume with no metric: no high-water mark" "0 (since --resume)" none 0/3 build
state --metric none --runs 2
HW=4 decides "--runs sets N" "3 (all)" none 3/2 observe
ledger "$O|$(e run 0 "$(m 4 6)")" "$O|$(e run 0 "$(m 4 6)")" "$O|$(e run 0 "$(m 6 6)")"
state --metric 6/6
HW=6 AP=yes decides "P == T again after an all-pass entry: the walk is empty, so build" \
  "0 (since the last all-pass entry)" none 0/3 build
# nolog <args...> : run the helper with no --issue; sets out / rc.
nolog() {
  out="$(PATH="$stub:$PATH" bounded 10 bash "$STATE" --repo o/n --runs 3 "$@" 2>/dev/null)"
  rc=$?
  out="$(printf '%s' "$out" | paste -sd '|' -)"
}
nolog
decides "no ledger yet: build" "0 (no ledger yet)" none 0/3 build
nolog --metric 2/2
AP=yes decides "no ledger yet, P == T: all-pass, beside build" "0 (no ledger yet)" none 0/3 build
nolog --metric 3/6 --resume
HW=3 decides "no ledger yet, --resume: the mark is this run's P" "0 (no ledger yet)" none 0/3 build

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
  HW=4 decides "a metric that is not valid ($bad) falls back to the merge rule" "2 (all)" none \
    0/3 build
done
ledger "$O|$(e run 0 "$(m 5 5)")" "$O|$(e run 0 '{"passed": 3, "total": 3, "x": 1}')"
state
HW=3 decides "an all-pass entry with extra metric keys still ends the walk" \
  "0 (since the last all-pass entry)" none 0/3 build

# planning-failed: the newest run entry's planning_failed.
T7="$(printf '%040d' 7)"
# pf <tip> <reason> : a P == T run entry whose next-milestone planning failed.
pf() { e run 0 "$(m 5 5)" | jq -c --arg t "$1" --arg r "$2" '. + {planning_failed: {tip: $t, reason: $r}}'; }
ledger "$O|$(e run 0 "$(m 4 6)")" "$O|$(pf "$T7" "milestone invalid")"
state --metric 5/5
HW=5 AP=yes PF="$T7 milestone invalid" decides "a run whose planning failed: its tip and reason" \
  "0 (since the last all-pass entry)" none 0/3 build
ledger "$O|$(pf "$T7" "milestone invalid")" "$O|$(e observe 0 "$(m 5 5)")" \
  "$O|$(e observe 0 "$(m 5 5)")"
state --metric 5/5
HW=5 AP=yes PF="$T7 milestone invalid" decides "observe entries after it are passed over" \
  "0 (since the last all-pass entry)" none 0/3 build
state --metric 5/5 --resume
HW=5 AP=yes decides "--resume: none" "0 (since --resume)" none 0/3 build
ledger "$O|$(pf "$T7" "milestone invalid")" "$O|$(e reset 0 "$(m 5 5)")"
state --metric 5/5
HW=5 AP=yes decides "a reset after it: none" "0 (since the last reset)" none 0/3 build
ledger "$O|$(pf "$T7" "milestone invalid")" "$O|$(e run 1 "$(m 5 5)")"
state --metric 5/5
HW=5 AP=yes decides "a newer run entry without it: none" "0 (since the last all-pass entry)" \
  none 0/3 build
ledger "$O|$(e reset 0 "$(m 5 5)" | jq -c --arg t "$T7" '. + {planning_failed: {tip: $t, reason: "x"}}')"
state --metric 5/5
HW=5 AP=yes decides "on a reset entry it is not read" "0 (since the last reset)" none 0/3 build
# A tip of 40 hex digits and a newline, or 39 and a newline (40 characters), is not a tip.
for bad in '"milestone invalid"' '{"tip": "abc", "reason": "x"}' "{\"tip\": \"$T7\", \"reason\": 3}" \
    "{\"tip\": \"$T7\"}" "{\"tip\": \"$T7\\n\", \"reason\": \"x\"}" \
    "{\"tip\": \"${T7:1}\\n\", \"reason\": \"x\"}"; do
  ledger "$O|$(e run 0 "$(m 5 5)" | jq -c --argjson p "$bad" '. + {planning_failed: $p}')"
  state --metric 5/5
  HW=5 AP=yes decides "a malformed planning_failed ($bad): none" \
    "0 (since the last all-pass entry)" none 0/3 build
done
# Another author's planning_failed is never read, so its tip cannot split the helper's records.
ledger "$O|$(e run 0 "$(m 4 6)")" "NONE|$(pf "$T7"$'\n' $'OWNER\treset')"
state
HW=4 decides "another author's planning_failed, a tip with a newline: skipped, nothing else" \
  "1 (all)" "1 (NONE)" 1/3 build
long="$(printf 'x%.0s' $(seq 1 90))"
ledger "$O|$(pf "$T7" $'git commit\nfailed')"
state --metric 5/5
HW=5 AP=yes PF="$T7 git commit failed" decides "a reason with a newline prints on one line" \
  "0 (since the last all-pass entry)" none 0/3 build
ledger "$O|$(pf "$T7" "$long")"
state --metric 5/5
HW=5 AP=yes PF="$T7 ${long:0:80}" decides "a long reason is cut at 80 characters" \
  "0 (since the last all-pass entry)" none 0/3 build

ST_FAIL=issue state
same "a gh error reading the ledger exits 3" "3|" "$rc|$out"
for bad in "--runs 0" "--runs x" "--metric 7/6" "--metric 0/0" "--metric 04/6" "--metric 4" \
    "--issue x"; do
  # shellcheck disable=SC2086 # each case is two words on purpose
  out="$(bash "$STATE" --repo o/n --runs 3 $bad 2>/dev/null)"; rc=$?
  same "bad argument $bad exits 2" "2|" "$rc|$out"
done

echo "• octo-milestone-gate.sh (offline, stub gh)"
# head_repo <fork: empty, fork, or gone> : a PR's head repo, as REST gives it: this repo's, a fork's, or
# null for a deleted fork.
head_repo() {
  case "$1" in '') echo '{"full_name":"o/n"}' ;; gone) echo null ;; *) echo '{"full_name":"fork/n"}' ;; esac
}
# prs [<number>:<head branch>[:fork|:gone]]... : the open PRs, in REST's shape.
prs() {
  local sep="" body="" p num br fk
  for p in "$@"; do
    IFS=: read -r num br fk <<<"$p"
    body="$body$sep$(printf '{"number":%s,"html_url":"https://github.com/o/n/pull/%s","head":{"ref":"%s","repo":%s},"base":{"repo":{"full_name":"o/n"}}}' \
      "$num" "$num" "$br" "$(head_repo "$fk")")"
    sep=","
  done
  printf '[%s]\n' "$body" >"$ST_DIR/prs.json"
}
# closed [<number>:<head branch>:<CLOSED|MERGED>[:fork|:gone]]... : the closed and merged PRs,
# newest first, as REST lists them (state closed; merged_at set once merged); PR <number>'s head
# commit is $(sha <number>), and each closed at $CLOSED_AT (null when it is `null`).
CLOSED_AT=2026-01-02T00:00:00Z
closed() {
  local sep="" body="" p num br st fk at
  at="\"$CLOSED_AT\""; [ "$CLOSED_AT" != null ] || at=null
  for p in "$@"; do
    IFS=: read -r num br st fk <<<"$p"
    body="$body$sep$(printf '{"number":%s,"state":"closed","merged_at":%s,"head":{"ref":"%s","sha":"%s","repo":%s},"base":{"repo":{"full_name":"o/n"}},"closed_at":%s}' \
      "$num" "$([ "$st" = MERGED ] && echo "$at" || echo null)" "$br" "$(sha "$num")" \
      "$(head_repo "$fk")" "$at")"
    sep=","
  done
  printf '[%s]\n' "$body" >"$ST_DIR/prs-closed.json"
}
# tip <n> : the default branch's tip is $(sha <n>).
tip() { ST_TIP="$(sha "$1")"; printf '{"object":{"sha":"%s"}}\n' "$ST_TIP" >"$ST_DIR/ref.json"; }
# compared <pr> <n> : comparing the tip with PR <pr>'s head gives the merge base $(sha <n>).
compared() {
  ST_CMP_HEAD="$(sha "$1")"
  printf '{"merge_base_commit":{"sha":"%s"}}\n' "$(sha "$2")" >"$ST_DIR/compare.json"
}
# tipdate <date> : the tip's committer date (by default a day after $CLOSED_AT).
tipdate() { printf '{"committer":{"date":"%s"}}\n' "$1" >"$ST_DIR/commit.json"; }
tipdate 2026-01-03T00:00:00Z
# tipruns [<id>:<status>[:<event>[:<head repo>]]]... : evals.yml's runs for the tip, newest first.
tipruns() {
  local sep="" body="" r id st ev hr
  for r in "$@"; do
    IFS=: read -r id st ev hr <<<"$r"
    body="$body$sep$(printf '{"id":%s,"status":"%s","event":"%s","head_repository":{"full_name":"%s"}}' \
      "$id" "$st" "${ev:-push}" "${hr:-o/n}")"
    sep=","
  done
  printf '{"total_count":%s,"workflow_runs":[%s]}\n' "$#" "$body" >"$ST_DIR/runs-tip.json"
}
export ST_TIP ST_CMP_HEAD
# gate <rate> <head> [args...] : run the helper; sets out (lines joined by |) and rc.
gate() {
  out="$(PATH="$stub:$PATH" bounded 10 bash "$GATE" --repo o/n --rate "$1" --head "$2" "${@:3}" \
    2>/dev/null)"
  rc=$?
  out="$(printf '%s' "$out" | paste -sd '|' -)"
}
H78="$(sha 78)"
prs 12:42-fix-login 13:milestone-2-x:fork
tip 78
tipruns
gate 5/5 "$H78"
same "P == T, at the tip, no next-milestone PR: plan" \
  "0|milestone-pr: none|tip: $H78|decision: plan" "$rc|$out"
ST_FAIL=pr-open gate 5/5 "$H78" --buildable 2
same "buildable work comes first, with no gh call" \
  "0|milestone-pr: none|tip: unchecked|decision: build" "$rc|$out"
gate 5/5 "$H78" --buildable 0
same "--buildable 0: plan" "0|milestone-pr: none|tip: $H78|decision: plan" "$rc|$out"
tip 79
gate 5/5 "$H78"
same "P == T on an older commit than the tip, no run for the tip: stale dispatch" \
  "0|milestone-pr: none|tip: $(sha 79)|decision: stale dispatch" "$rc|$out"
tipruns 90:completed 91:in_progress:pull_request 92:queued:push:fork/n
gate 5/5 "$H78"
same "completed, pull_request, and another repo's runs don't count: stale dispatch" \
  "0|milestone-pr: none|tip: $(sha 79)|decision: stale dispatch" "$rc|$out"
tipruns 93:queued 94:in_progress:workflow_dispatch
gate 5/5 "$H78"
same "a push run for the tip queued: stale wait, the newest" \
  "0|milestone-pr: none|tip: $(sha 79)|decision: stale wait 93" "$rc|$out"
tipruns 94:in_progress:workflow_dispatch:O/N
gate 5/5 "$H78"
same "a dispatch run in progress (the repo compares case-insensitively): stale wait" \
  "0|milestone-pr: none|tip: $(sha 79)|decision: stale wait 94" "$rc|$out"
tipruns
tip 78
prs 31:milestone-3-sync 12:42-fix-login 30:milestone-2-export
gate 5/5 "$H78"
same "a next-milestone PR open: open, the lowest of two, nothing else read" \
  "0|milestone-pr: 30 https://github.com/o/n/pull/30|tip: unchecked|decision: open 30" "$rc|$out"
gate 4/6 "$H78"
same "a next-milestone PR open wins over P < T too" \
  "0|milestone-pr: 30 https://github.com/o/n/pull/30|tip: unchecked|decision: open 30" "$rc|$out"
prs 12:42-fix-login 14:xmilestone-2
ST_FAIL=ref gate 4/6 "$H78"
same "P < T: not all-pass, the tip not read" \
  "0|milestone-pr: none|tip: unchecked|decision: not all-pass" "$rc|$out"
ST_FAIL=ref gate none none
same "no metric: not all-pass" "0|milestone-pr: none|tip: unchecked|decision: not all-pass" \
  "$rc|$out"
prs
gate 5/5 "$H78"
same "no open PR at all: plan" "0|milestone-pr: none|tip: $H78|decision: plan" "$rc|$out"

# The last run's planning failed at the tip.
ST_FAIL=pr-closed gate 5/5 "$H78" --failed-tip "$H78"
same "planning failed at this tip: failed, before the closed PRs are read" \
  "0|milestone-pr: none|tip: $H78|decision: failed" "$rc|$out"
gate 5/5 "$H78" --failed-tip "$(sha 77)"
same "planning failed at an older tip: plan" "0|milestone-pr: none|tip: $H78|decision: plan" \
  "$rc|$out"

# A milestone PR a human closed unmerged.
closed 40:milestone-2-export:CLOSED 39:41-fix:MERGED 35:milestone-1-x:MERGED
compared 40 78
ST_FAIL=commit gate 5/5 "$H78"
same "the newest milestone PR closed unmerged, the tip unchanged: declined, reading no date" \
  "0|milestone-pr: none|tip: $H78|decision: declined 40" "$rc|$out"
ST_FAIL=compare gate 5/5 "$H78" --resume
same "--resume lifts declined, comparing nothing" "0|milestone-pr: none|tip: $H78|decision: plan" \
  "$rc|$out"
tip 80
compared 40 78
gate 5/5 "$(sha 80)"
same "the tip moved since it was planned: plan" \
  "0|milestone-pr: none|tip: $(sha 80)|decision: plan" "$rc|$out"
tip 81
compared 40 78
tipdate 2026-01-01T12:00:00Z
gate 5/5 "$(sha 81)"
same "ready work merged while it was open, then a human closed it: declined (by date)" \
  "0|milestone-pr: none|tip: $(sha 81)|decision: declined 40" "$rc|$out"
tipdate "$CLOSED_AT"
gate 5/5 "$(sha 81)"
same "the tip committed at the very time it closed: declined" \
  "0|milestone-pr: none|tip: $(sha 81)|decision: declined 40" "$rc|$out"
ST_CMP404=1 gate 5/5 "$(sha 81)"
same "a compare 404 (no common ancestor), the tip no newer than the close: declined (by date)" \
  "0|milestone-pr: none|tip: $(sha 81)|decision: declined 40" "$rc|$out"
tipdate 2026-01-03T00:00:00Z
ST_CMP404=1 gate 5/5 "$(sha 81)"
same "a compare 404 with a newer tip: not declined, no gate error: plan" \
  "0|milestone-pr: none|tip: $(sha 81)|decision: plan" "$rc|$out"
ST_FAIL=commit gate 5/5 "$(sha 81)"
same "a gh error reading the tip's date exits 3" "3|" "$rc|$out"
tipdate "2026-01-03 00:00:00"
gate 5/5 "$(sha 81)"
same "a tip date that is not ISO 8601 UTC exits 3" "3|" "$rc|$out"
tipdate 2026-01-03T00:00:00Z
CLOSED_AT=null closed 40:milestone-2-export:CLOSED
gate 5/5 "$(sha 81)"
same "a closedAt that is not ISO 8601 UTC exits 3" "3|" "$rc|$out"
closed 40:milestone-2-export:CLOSED
tip 79
compared 40 79
gate 5/5 "$H78"
same "declined wins over a stale metric" "0|milestone-pr: none|tip: $(sha 79)|decision: declined 40" \
  "$rc|$out"
tip 78
closed 41:milestone-2-sync:MERGED 40:milestone-2-export:CLOSED
ST_FAIL=compare gate 5/5 "$H78"
same "a newer milestone PR merged: plan, comparing nothing" \
  "0|milestone-pr: none|tip: $H78|decision: plan" "$rc|$out"
closed 43:milestone-2-x:CLOSED:fork 42:44-fix:CLOSED 41:milestone-2-sync:MERGED
ST_FAIL=compare gate 5/5 "$H78"
same "a fork's milestone-* PR and another branch's PR don't count" \
  "0|milestone-pr: none|tip: $H78|decision: plan" "$rc|$out"
closed 44:milestone-2-y:CLOSED:gone 41:milestone-2-sync:MERGED
ST_FAIL=compare gate 5/5 "$H78"
same "a deleted fork's milestone-* PR (head repo null) doesn't count" \
  "0|milestone-pr: none|tip: $H78|decision: plan" "$rc|$out"
closed
prs 15:milestone-2-y:gone 12:42-fix-login
gate 5/5 "$H78"
same "an open PR from a deleted fork on a milestone-* branch doesn't count: plan" \
  "0|milestone-pr: none|tip: $H78|decision: plan" "$rc|$out"
prs

for step in pr-open repo ref; do
  ST_FAIL=$step gate 5/5 "$H78"
  same "a gh error reading $step exits 3, deciding nothing" "3|" "$rc|$out"
done
closed 40:milestone-2-export:CLOSED
compared 40 78
for step in pr-closed compare; do
  ST_FAIL=$step gate 5/5 "$H78"
  same "a gh error reading $step exits 3, deciding nothing" "3|" "$rc|$out"
done
closed
tip 79
ST_FAIL=tipruns gate 5/5 "$H78"
same "a gh error listing the tip's runs exits 3" "3|" "$rc|$out"
# REST names a default branch even for an empty repo, whose tip read then answers 409.
ST_EMPTY=1 gate 5/5 "$H78"
same "an empty repo (its tip read 409s) exits 3, deciding nothing" "3|" "$rc|$out"
printf '{"object":{"sha":"abc"}}\n' >"$ST_DIR/ref.json"
gate 5/5 "$H78"
same "a tip that is not a commit exits 3" "3|" "$rc|$out"
for bad in "--rate 5/5" "--rate 7/6 --head none" "--rate 5/5 --head abc" "--rate x --head none" \
    "--rate 0/0 --head none" "--rate 5/5 --head none --buildable x" \
    "--rate 5/5 --head none --buildable -1" "--rate 5/5 --head none --failed-tip abc"; do
  # shellcheck disable=SC2086 # each case is several words on purpose
  out="$(bash "$GATE" --repo o/n $bad 2>/dev/null)"; rc=$?
  same "bad argument $bad exits 2" "2|" "$rc|$out"
done
out="$(bash "$GATE" --repo 'o/n"' --rate none --head none 2>/dev/null)"; rc=$?
same "a --repo with a quote exits 2" "2|" "$rc|$out"

echo "• octo-web-allowed.sh (offline, throwaway settings)"
WR="$tmp/web/repo" WH="$tmp/web/home"
# settings <repo|local|home> <json> : write that settings file.
settings() {
  local f
  case "$1" in
    repo) f="$WR/.claude/settings.json" ;; local) f="$WR/.claude/settings.local.json" ;;
    home) f="$WH/.claude/settings.json" ;;
  esac
  mkdir -p "$(dirname "$f")" && printf '%s\n' "$2" >"$f"
}
# web <label> <wanted line> : run the helper on $WR with $WH as HOME; exit 0 and that line.
web() {
  out="$(HOME="$WH" bounded 10 bash "$SCRIPTS_DIR/octo-web-allowed.sh" "$WR" 2>/dev/null)"
  same "$1" "0|web: $2" "$?|$out"
}
mkdir -p "$WR" "$WH"
web "no settings files: not allowed" 'not allowed (no bare "WebSearch" in permissions.allow)'
BOTH='{"permissions": {"allow": ["Bash(gh:*)", "WebSearch", "WebFetch"]}}'
settings repo "$BOTH"
web "both bare in the repo's settings: allowed" allowed
rm -r "$WR/.claude"
settings local '{"permissions": {"allow": ["WebSearch"]}}'
settings home '{"permissions": {"allow": ["WebFetch"]}, "model": "x"}'
web "one in settings.local.json, one in ~/.claude: allowed" allowed
rm "$WH/.claude/settings.json"
web "only WebSearch allowed: not allowed" 'not allowed (no bare "WebFetch" in permissions.allow)'
settings local '{"permissions": {"allow": ["WebSearch", "WebFetch(domain:x.example)"]}}'
web "a scoped allow is not a bare one: not allowed" \
  'not allowed (no bare "WebFetch" in permissions.allow)'
settings local "$BOTH"
settings home '{"permissions": {"deny": ["WebFetch(domain:evil.example)"]}}'
web "a scoped deny in another file wins over the allow" \
  "not allowed (~/.claude/settings.json's permissions.deny names WebFetch)"
settings home '{"permissions": {"ask": ["WebSearch"]}}'
web "a bare ask wins over the allow" \
  "not allowed (~/.claude/settings.json's permissions.ask names WebSearch)"
rm "$WH/.claude/settings.json"
settings local '{"permissions": {"allow": ["WebSearch", "WebFetch"], "deny": ["WebFetch"]}}'
web "a deny in the same file wins over the allow" \
  "not allowed (.claude/settings.local.json's permissions.deny names WebFetch)"
settings local '{"permissions": {"allow": ["WebSearch", "WebFetch"], "ask": ["WebFetchX"]}}'
web "an ask naming another tool doesn't count: allowed" allowed
settings repo '{"permissions": {"allow": ["WebSearch", "WebFetch"]},'
web "a file that isn't JSON allows nothing" \
  "not allowed (.claude/settings.json is not valid settings JSON)"
for bad in '[]' '{"permissions": []}' '{"permissions": {"deny": "WebFetch"}}'; do
  settings repo "$bad"
  web "settings with the wrong shape ($bad) allow nothing" \
    "not allowed (.claude/settings.json is not valid settings JSON)"
done
for bad in "" "a b" "--bogus" "$tmp/web/missing"; do
  # shellcheck disable=SC2086 # each case is zero to two words on purpose
  out="$(bash "$SCRIPTS_DIR/octo-web-allowed.sh" $bad 2>/dev/null)"; rc=$?
  same "bad arguments (${bad:-none}) exit 2" "2|" "$rc|$out"
done

echo "• the stub gh refuses GraphQL and porcelain, as a Claude Code cloud session does"
out="$(PATH="$stub:$PATH" gh pr list --repo o/n 2>&1)"; rc=$?
same "porcelain gets the proxy's 403" "1|GraphQL is not available" "$rc|$(printf '%s' "$out" | grep -o 'GraphQL is not available')"
out="$(PATH="$stub:$PATH" gh api graphql -f query='{viewer{login}}' 2>&1)"; rc=$?
same "gh api graphql gets it too" "1|GraphQL is not available" "$rc|$(printf '%s' "$out" | grep -o 'GraphQL is not available')"
grep -v -e '^pr list --repo o/n$' -e '^api graphql' "$ST_DIR/rejected" >"$ST_DIR/rejected.helpers"
same "no helper call was refused" "" "$(cat "$ST_DIR/rejected.helpers")"

echo
echo "autopilot: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
