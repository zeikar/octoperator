#!/usr/bin/env bash
# merge-gate.sh — offline tests for auto's REST merge gate helpers: octo-merge-state.sh,
# octo-ci-wait.sh, and octo-merge.sh.
#
# Usage:
#   bash scripts/test/merge-gate.sh
#
# Runs each helper against a stub `gh` that plays a small GitHub over REST only: it serves
# `gh api repos/...` from fixture files (pull requests, their merge state read by read, a
# commit's check runs, check suites, and statuses poll by poll), applies the merge and the branch delete, and
# rejects `gh api graphql` and every porcelain command (`gh pr`, ...) with the Claude Code cloud
# proxy's 403, as a cloud session does. A list endpoint is served two items a page, running the
# --jq filter once per page as gh does. Covers: bad arguments (exit 2, no gh call); every
# `mergeable_state` (clean, dirty, blocked, behind, unstable, has_hooks, draft, an unknown word),
# null and `unknown` then clean, a state that never settles, a malformed value, and a gh error;
# CI green (success, neutral, skipped, a status), no checks (none only after a re-read), checks
# that register by the re-read, each failing conclusion and status (fail-fast), a pending timeout,
# pending then green, a re-run (the newest check run of a name in its suite wins, either way),
# same-named runs in two suites (both count), a check suite with runs still pending, a 0-run
# queued suite (ignored), stale, every page, a failed read retried, and a statuses API that keeps
# failing; the merge 200 (a regular merge pinned to the reviewed head, then the branch deleted),
# 405, 409 (the head moved: GitHub compares the sha), a merge that lands though the call failed,
# a merge whose read-back lags, a call and read-back that both fail, the branch delete's 204,
# 403, and 422 (already gone), and a fork's, a deleted fork's, or the default branch kept. No
# call is ever rejected.
#
# Nothing here calls the real gh or the network. Exits 0 when every check passes, 1 when any fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

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

command -v jq >/dev/null || { echo "merge-gate: jq is required for the stub gh" >&2; exit 1; }
# No `set -e`: bail out explicitly, or an empty $tmp would point the stub at the real checkout.
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "merge-gate: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# The stub's state lives in $FX: pulls/<n>.json (a pull request), ms/<n> (its mergeable_state,
# one per read, the last line repeating; "null" is null), merge/<n> (how the merge call answers:
# 405, or 500 or 500-merged, a 500 after which the PR is or isn't merged; otherwise GitHub's
# rules: 409 unless sha is the head's, then merged), lag (the PR reads back unmerged after the
# merge, a lagging replica), branches (the repo's branch names, one per
# line), delete-403 (the branch delete is refused, as the cloud proxy does), checks/<sha>.json,
# suites/<sha>.json, and statuses/<sha>.json (a commit's check runs, check suites, and statuses,
# JSON arrays; <sha>.<k>.json answers the k-th read instead), fail (an ERE matched against "<METHOD> <endpoint>" → a 500), fail-once (the
# same, once), and fail-after-merge (every read after a merge call → a 500). It logs every call to
# log and $ALL_LOG, every rejected one to $ALL_REJECTED, and every write to writes, each field as
# raw:<k=v> (-f) or typed:<k=v> (-F). Like gh, it prints an error's body on stdout.
stub="$tmp/bin"
FX="$tmp/fx"
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
call=$(printf '%s' "$*" | tr '\n' ' ')
echo "$call" >>"$FX/log"; echo "$call" >>"$ALL_LOG"
reject() {
  echo "$call" >>"$ALL_REJECTED"
  echo 'gh: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). (HTTP 403)' >&2
  exit 1
}
[ "${1:-}" = api ] || reject "$@"
shift
method="" ep="" jq="." paginate=0 fields=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X | --method) method="$2"; shift 2 ;;
    --jq) jq="$2"; shift 2 ;;
    -f | --raw-field) fields="$fields"$'\n'"raw:$2"; shift 2 ;;
    -F | --field) fields="$fields"$'\n'"typed:$2"; shift 2 ;;
    --paginate) paginate=1; shift ;;
    -*) echo "stub: unknown flag $1" >&2; exit 9 ;;
    *) [ -z "$ep" ] || { echo "stub: two endpoints" >&2; exit 9; }; ep="$1"; shift ;;
  esac
done
[ "$ep" != graphql ] || reject api graphql
[ -n "$method" ] || { [ -n "$fields" ] && method=POST || method=GET; }
err() { printf '{"message":"%s","status":"%s"}\n' "$2" "$1"; echo "gh: $2 (HTTP $1)" >&2; exit 1; }
if [ -s "$FX/fail" ] && printf '%s %s\n' "$method" "$ep" | grep -Eq -f "$FX/fail"; then
  err 500 "Server Error"
fi
if [ -s "$FX/fail-once" ] && printf '%s %s\n' "$method" "$ep" | grep -Eq -f "$FX/fail-once"; then
  rm -f "$FX/fail-once"; err 500 "Server Error"
fi
if [ "$method" = GET ] && [ -e "$FX/fail-after-merge" ] && [ -e "$FX/merge-called" ]; then
  err 500 "Server Error"
fi
field() { printf '%s\n' "$fields" | sed -n "s/^[a-z]*:$1=//p"; }
logged() { printf '%s' "$fields" | tr '\n' ' '; }
# count <key> : this call's number among the calls counted under <key>.
count() { local n; n=$(( $(cat "$FX/count-$1" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FX/count-$1"; echo "$n"; }
# pages <key> : serve the JSON array on stdin two items a page, each page as {<key>: [...]}, only
# the first page without --paginate, running the --jq filter on each page, as gh does.
pages() {
  local all n i=0
  all=$(cat); n=$(jq length <<<"$all")
  while :; do
    jq -c --arg k "$1" '{($k): .['"$i:$((i + 2))"'], total_count: length}' <<<"$all" | jq -r "$jq" || exit 9
    i=$((i + 2))
    [ "$paginate" -eq 1 ] && [ "$i" -lt "$n" ] || break
  done
}
# seq_file <dir> <sha> : the fixture for this read, <sha>.<k>.json or else <sha>.json, or [].
seq_file() {
  local k; k=$(count "$1-$2")
  if [ -f "$FX/$1/$2.$k.json" ]; then cat "$FX/$1/$2.$k.json"
  elif [ -f "$FX/$1/$2.json" ]; then cat "$FX/$1/$2.json"
  else echo '[]'; fi
}
case "$method $ep" in
  "GET repos/o/n/pulls/"*)
    n=${ep##*/}; f="$FX/pulls/$n.json"; [ -f "$f" ] || err 404 "Not Found"
    ms=""
    if [ -f "$FX/ms/$n" ] && jq -e '.merged | not' "$f" >/dev/null; then
      k=$(count "ms-$n"); total=$(wc -l <"$FX/ms/$n" | tr -d ' ')
      [ "$k" -le "$total" ] || k=$total
      ms=$(sed -n "${k}p" "$FX/ms/$n")
    fi
    if [ -n "$ms" ]; then
      jq --arg ms "$ms" '.mergeable_state = (if $ms == "null" then null else $ms end)' "$f" | jq -r "$jq"
    elif [ -e "$FX/lag" ] && [ -e "$FX/merge-called" ]; then
      jq '.merged = false | .state = "open" | .merge_commit_sha = "test-merge"' "$f" | jq -r "$jq"
    else jq -r "$jq" "$f"; fi ;;
  "PUT repos/o/n/pulls/"*/merge)
    n=${ep%/merge}; n=${n##*/}; f="$FX/pulls/$n.json"; [ -f "$f" ] || err 404 "Not Found"
    touch "$FX/merge-called"
    echo "MERGE $n$(logged)" >>"$FX/writes"
    mark() { jq '.merged = true | .state = "closed" | .merge_commit_sha = "m\(.number)"' "$f" >"$f.new" && mv "$f.new" "$f"; }
    case "$(cat "$FX/merge/$n" 2>/dev/null)" in
      405) err 405 "Pull Request is not mergeable" ;;
      500) err 500 "Server Error" ;;
      500-merged) mark; err 500 "Server Error" ;;
    esac
    [ "$(field sha)" = "$(jq -r .head.sha "$f")" ] || err 409 "Head branch was modified. Review and try the merge again."
    [ "$(field merge_method)" = merge ] || err 422 "stub: only merge_method=merge"
    mark
    jq -n --arg n "$n" '{sha: "m\($n)", merged: true, message: "Pull Request successfully merged"}' | jq -r "$jq" ;;
  "DELETE repos/o/n/git/refs/heads/"*)
    # GitHub decodes the path: %23 is #.
    b=${ep#repos/o/n/git/refs/heads/}; b=$(printf '%b' "${b//%/\\x}")
    echo "DELETE $b" >>"$FX/writes"
    [ ! -e "$FX/delete-403" ] || err 403 "Forbidden"
    grep -Fxq -- "$b" "$FX/branches" 2>/dev/null || err 422 "Reference does not exist"
    grep -Fxv -- "$b" "$FX/branches" >"$FX/branches.new"; mv "$FX/branches.new" "$FX/branches" ;;
  "GET repos/o/n/commits/"*"/check-runs?filter=latest&per_page=100")
    s=${ep#repos/o/n/commits/}; s=${s%%/*}; seq_file checks "$s" | pages check_runs ;;
  "GET repos/o/n/commits/"*"/check-suites?per_page=100")
    s=${ep#repos/o/n/commits/}; s=${s%%/*}; seq_file suites "$s" | pages check_suites ;;
  "GET repos/o/n/commits/"*"/status?per_page=100")
    s=${ep#repos/o/n/commits/}; s=${s%%/*}; seq_file statuses "$s" | pages statuses ;;
  *) echo "stub: unexpected $method $ep" >&2; exit 9 ;;
esac
STUB
chmod +x "$stub/gh"
ALL_LOG="$tmp/all-log" ALL_REJECTED="$tmp/all-rejected"
export FX ALL_LOG ALL_REJECTED

# fresh : an empty GitHub.
fresh() { rm -rf "$FX"; mkdir -p "$FX/pulls" "$FX/ms" "$FX/merge" "$FX/checks" "$FX/suites" "$FX/statuses"; }
SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
# pr <n> [head [head repo ("null": a deleted fork) [head sha]]] : write pulls/<n>.json, open, into
# main, the repo's default branch; its head branch is in branches too.
pr() {
  jq -n --argjson n "$1" --arg h "${2:-$1-x}" --arg r "${3:-o/n}" --arg s "${4:-$SHA}" \
    '{number: $n, state: "open", merged: false, draft: false, mergeable_state: "clean",
      merge_commit_sha: "test-merge", changed_files: 1,
      head: {ref: $h, sha: $s, repo: (if $r == "null" then null else {full_name: $r} end)},
      base: {ref: "main", repo: {full_name: "o/n", default_branch: "main"}}}' >"$FX/pulls/$1.json"
  printf '%s\n' "${2:-$1-x}" >>"$FX/branches"
}
# run <helper> [args...] : the helper against the stub; sets out (stdout), errout, rc, writes.
run() {
  local h="$SCRIPTS_DIR/$1"; shift
  out="$(PATH="$stub:$PATH" bounded 30 bash "$h" "$@" 2>"$tmp/stderr")"
  rc=$?
  errout="$(cat "$tmp/stderr")"
  writes="$(cat "$FX/writes" 2>/dev/null)"
}
# calls <ERE> : how many logged calls match.
calls() { grep -cE -- "$1" "$FX/log" 2>/dev/null; }
nl=$'\n'

echo "• the stub rejects GraphQL and porcelain, as the cloud proxy does"
fresh
o="$(PATH="$stub:$PATH" gh api graphql -f query='{viewer{login}}' 2>&1)"; r=$?
same "gh api graphql is refused with the proxy's 403" \
  "1|gh: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). (HTTP 403)" \
  "$r|$o"
PATH="$stub:$PATH" gh pr merge 1 --repo o/n --merge >/dev/null 2>&1
same "gh pr merge is refused too" 1 "$?"
PATH="$stub:$PATH" gh pr checks 1 --repo o/n --watch >/dev/null 2>&1
same "gh pr checks is refused too" 1 "$?"
rm -f "$ALL_LOG" "$ALL_REJECTED"

echo "• bad arguments (exit 2, no gh call)"
fresh
while IFS='|' read -r helper args; do
  # shellcheck disable=SC2086 # each case is several words on purpose
  o="$(PATH="$stub:$PATH" bounded 10 bash "$SCRIPTS_DIR/$helper" $args 2>/dev/null)"; r=$?
  same "$helper ${args:-(no arguments)} exits 2" "2|" "$r|$o"
done <<CASES
octo-merge-state.sh|
octo-merge-state.sh|--repo o/n
octo-merge-state.sh|--repo o/n --pr x
octo-merge-state.sh|--repo o/n --pr 1 --tries 0
octo-merge-state.sh|--repo o/n --pr 1 --interval -1
octo-ci-wait.sh|
octo-ci-wait.sh|--repo o/n
octo-ci-wait.sh|--sha $SHA
octo-ci-wait.sh|--repo on --sha $SHA
octo-ci-wait.sh|--repo o/n --sha abc123
octo-ci-wait.sh|--repo o/n --sha ${SHA}1
octo-ci-wait.sh|--repo o/n --sha $SHA --timeout 3601
octo-ci-wait.sh|--repo o/n --sha $SHA --timeout 99999999999999999999
octo-ci-wait.sh|--repo o/n --sha $SHA --timeout x
octo-ci-wait.sh|--repo o/n --sha $SHA --interval 0
octo-ci-wait.sh|--repo o/n --sha $SHA --interval 3601
octo-merge.sh|
octo-merge.sh|--repo o/n --pr 1
octo-merge.sh|--repo o/n --sha $SHA
octo-merge.sh|--pr 1 --sha $SHA
octo-merge.sh|--repo o/n/x --pr 1 --sha $SHA
octo-merge.sh|--repo o/n --pr 0 --sha $SHA
octo-merge.sh|--repo o/n --pr 01 --sha $SHA
octo-merge.sh|--repo o/n --pr 1 --sha abc123
octo-merge.sh|--repo o/n --pr 1 --sha ${SHA//1/G}
CASES
same "no gh call for bad arguments" "" "$(cat "$FX/log" 2>/dev/null)"

echo "• octo-merge-state.sh"
for state in clean dirty blocked behind unstable has_hooks draft; do
  fresh; pr 7; echo "$state" >"$FX/ms/7"
  run octo-merge-state.sh --repo o/n --pr 7 --interval 0
  same "mergeable_state $state prints $(tr '[:lower:]' '[:upper:]' <<<"$state"), after one read" \
    "0|$(tr '[:lower:]' '[:upper:]' <<<"$state")|1" "$rc|$out|$(calls '^api repos/o/n/pulls/7 --jq')"
done
fresh; pr 7; printf 'null\nclean\n' >"$FX/ms/7"
run octo-merge-state.sh --repo o/n --pr 7 --interval 0
same "null (not computed yet), then clean: CLEAN after 2 reads" "0|CLEAN|2" "$rc|$out|$(calls pulls/7)"
fresh; pr 7; printf 'unknown\nnull\nclean\n' >"$FX/ms/7"
run octo-merge-state.sh --repo o/n --pr 7 --interval 0
same "unknown, null, then clean: CLEAN after 3 reads" "0|CLEAN|3" "$rc|$out|$(calls pulls/7)"
fresh; pr 7; printf 'null\n' >"$FX/ms/7"
run octo-merge-state.sh --repo o/n --pr 7 --interval 0
same "never computed: UNKNOWN after --tries (3) reads, a hold" "0|UNKNOWN|3" "$rc|$out|$(calls pulls/7)"
fresh; pr 7; printf 'unknown\nclean\n' >"$FX/ms/7"
run octo-merge-state.sh --repo o/n --pr 7 --tries 1
same "--tries 1: one read, UNKNOWN" "0|UNKNOWN|1" "$rc|$out|$(calls pulls/7)"
fresh; pr 7; printf 'unknown\nblocked\n' >"$FX/ms/7"
run octo-merge-state.sh --repo o/n --pr 7 --interval 0
same "unknown, then blocked: BLOCKED, final" "0|BLOCKED|2" "$rc|$out|$(calls pulls/7)"
fresh; pr 7; echo "some_new_state" >"$FX/ms/7"
run octo-merge-state.sh --repo o/n --pr 7 --interval 0
same "a lowercase value GitHub may add prints uppercased, so it holds" "0|SOME_NEW_STATE" "$rc|$out"
fresh; pr 7; echo 'Clean' >"$FX/ms/7"
run octo-merge-state.sh --repo o/n --pr 7 --interval 0
same "a value that is not a lowercase word: exit 1, nothing printed" "1|" "$rc|$out"
fresh
run octo-merge-state.sh --repo o/n --pr 7 --interval 0
same "a gh error (404): exit 1, not gh's code, nothing printed" "1|" "$rc|$out"

echo "• octo-ci-wait.sh"
# run_obj <id> <suite id> <name> <status> [conclusion] : one check run.
run_obj() {
  jq -nc --argjson id "$1" --argjson su "$2" --arg n "$3" --arg s "$4" --arg c "${5:-}" \
    '{id: $id, check_suite: {id: $su}, name: $n, status: $s,
      conclusion: (if $c == "" then null else $c end)}'
}
# checks <file> <id[/suite id] name status conclusion>... : write a check-runs fixture ("-" for no
# conclusion; suite 1 unless named).
checks() {
  local f="$1" id su; shift
  { while [ $# -ge 4 ]; do
      id=${1%%/*}; su=1; [ "$id" = "$1" ] || su=${1#*/}
      run_obj "$id" "$su" "$2" "$3" "$( [ "$4" = - ] || echo "$4")"; shift 4
    done; } | jq -s . >"$FX/checks/$f.json"
}
# suites <file> <id app runs status>... : write a check-suites fixture (runs: its
# latest_check_runs_count).
suites() {
  local f="$1"; shift
  { while [ $# -ge 4 ]; do
      jq -nc --argjson id "$1" --arg a "$2" --argjson r "$3" --arg s "$4" \
        '{id: $id, app: {slug: $a}, latest_check_runs_count: $r, status: $s}'; shift 4
    done; } | jq -s . >"$FX/suites/$f.json"
}
# statuses <file> <context state>... : write a commit-statuses fixture.
statuses() {
  local f="$1"; shift
  { while [ $# -ge 2 ]; do jq -nc --arg c "$1" --arg s "$2" '{context: $c, state: $s}'; shift 2; done; } |
    jq -s . >"$FX/statuses/$f.json"
}
ci() { run octo-ci-wait.sh --repo o/n --sha "$SHA" "$@"; }

fresh
checks "$SHA" 1 build completed success 2 docs completed skipped 3 lint completed neutral \
  4 "test (ubuntu)" completed success 5 "test (macos)" completed success
statuses "$SHA" ci/circle success
ci --timeout 0
same "success, skipped, and neutral check runs and a success status: green" "0|green" "$rc|$out"
same "one read each: the newest check runs (filter=latest), the check suites, and the statuses, every page" "1|1|1" \
  "$(calls "^api --paginate repos/o/n/commits/$SHA/check-runs\?filter=latest&per_page=100 ")|$(calls "^api --paginate repos/o/n/commits/$SHA/check-suites\?per_page=100 ")|$(calls "^api --paginate repos/o/n/commits/$SHA/status\?per_page=100 ")"
fresh
checks "$SHA" 1 a completed success 2 b completed success 3 c completed success 4 d completed success \
  5 e completed failure
ci --timeout 0
same "a failure on the third page is seen" "1|failed e" "$rc|$out"

fresh
ci --timeout 0 --interval 1
same "no check runs and no statuses: none only after a re-read one interval later, even at the timeout" \
  "0|none|2" "$rc|$out|$(calls check-runs)"
fresh; checks "$SHA.1"; checks "$SHA" 1 build completed success
ci --timeout 0 --interval 1
same "nothing on the first read, a check run by the re-read: green, not none" "0|green|2" \
  "$rc|$out|$(calls check-runs)"
fresh; checks "$SHA.1"; checks "$SHA" 1 build completed failure
ci --timeout 0 --interval 1
same "nothing on the first read, a failure by the re-read: failed" "1|failed build" "$rc|$out"
fresh; suites "$SHA" 5 vercel 0 queued 6 claude 0 queued
ci --timeout 0 --interval 1
same "only check suites with no runs, queued for good: ignored, none" "0|none|2" "$rc|$out|$(calls check-suites)"
fresh; checks "$SHA" 1 build completed success; suites "$SHA" 5 vercel 0 queued 7 github-actions 1 completed
ci --timeout 0
same "a 0-run queued suite beside a completed one: ignored, green" "0|green" "$rc|$out"
fresh; checks "$SHA" 1/7 build completed success; suites "$SHA" 7 github-actions 3 in_progress
ci --timeout 0
same "a suite with runs still in progress, its listed runs all passed: pending, the suite named" \
  "1|pending github-actions check suite 7" "$rc|$out"
fresh; suites "$SHA" 7 github-actions 2 queued
ci --timeout 0
same "a suite registered with runs not listed yet: pending, not none" \
  "1|pending github-actions check suite 7|1" "$rc|$out|$(calls check-runs)"
fresh; checks "$SHA" 1/7 build completed failure; suites "$SHA" 7 github-actions 2 in_progress
ci --timeout 0
same "a failure in a suite still running: failed, at once" "1|failed build" "$rc|$out"
fresh; suites "$SHA.1" 7 github-actions 2 in_progress; checks "$SHA" 1/7 build completed success
suites "$SHA" 7 github-actions 2 completed
ci --interval 1
same "a suite pending, then completed: green" "0|green|2" "$rc|$out|$(calls check-suites)"

for c in failure cancelled timed_out action_required; do
  fresh; checks "$SHA" 1 build completed "$c" 2 test in_progress - 3 lint completed success
  ci --interval 1
  same "a $c check run: failed, at once (fail-fast)" "1|failed build|1" "$rc|$out|$(calls check-runs)"
done
for s in failure error; do
  fresh; checks "$SHA" 1 build completed success; statuses "$SHA" ci/a success deploy "$s"
  ci --timeout 0
  same "a status in $s: failed" "1|failed deploy" "$rc|$out"
done
fresh; checks "$SHA" 1 a completed failure 2 b completed timed_out; statuses "$SHA" c error
ci --timeout 0
same "every failure is named" "1|failed a, b, c" "$rc|$out"

fresh; checks "$SHA" 1 build in_progress - 2 test queued - 3 lint completed success
ci --timeout 0
same "still running at the timeout: pending, named" "1|pending build, test" "$rc|$out"
fresh; checks "$SHA" 1 build completed stale
ci --timeout 0
same "a stale check run is pending, as gh pr checks has it" "1|pending build" "$rc|$out"
fresh; checks "$SHA" 1 build completed success; statuses "$SHA" ci/a pending
ci --timeout 0
same "a pending status is pending" "1|pending ci/a" "$rc|$out"
fresh; checks "$SHA" 1 build in_progress -
ci --timeout 2 --interval 1
same "a 2s timeout at a 1s interval polls again, then gives up: pending" "1|pending build|yes" \
  "$rc|$out|$([ "$(calls check-runs)" -ge 2 ] && echo yes)"

fresh
checks "$SHA.1" 1 build in_progress - 2 test queued -
checks "$SHA" 1 build completed success 2 test completed success
ci --interval 1
same "pending, then green on the next poll" "0|green|2" "$rc|$out|$(calls check-runs)"

fresh; checks "$SHA" 1 test completed failure 2 build completed success 9 test completed success
ci --timeout 0
same "a re-run: the newest check run of a name wins (failed, then passed)" "0|green" "$rc|$out"
fresh; checks "$SHA" 9 test completed failure 2 build completed success 1 test completed success
ci --timeout 0
same "a re-run: the newest check run of a name wins (passed, then failed)" "1|failed test" "$rc|$out"
fresh; checks "$SHA" 1 test completed success 9 test in_progress -
ci --timeout 0
same "a re-run still running is pending, whatever the older run said" "1|pending test" "$rc|$out"
fresh; checks "$SHA" 1/10 "smoke (ubuntu)" in_progress - 2/20 "smoke (ubuntu)" completed success
ci --timeout 0
same "the same name in two suites (push and pull_request), the older-id one pending: pending" \
  "1|pending smoke (ubuntu)" "$rc|$out"
fresh; checks "$SHA" 1/10 "smoke (ubuntu)" completed failure 2/20 "smoke (ubuntu)" completed success
ci --timeout 0
same "the same name in two suites, the older-id one failed: failed" "1|failed smoke (ubuntu)" "$rc|$out"
fresh; checks "$SHA" 1/10 smoke completed failure 2/20 smoke completed success 3/10 smoke completed success
ci --timeout 0
same "two suites, each with a re-run: the newest of each suite counts, green" "0|green" "$rc|$out"

fresh; checks "$SHA" 1 build completed success; echo '/status\?' >"$FX/fail"
ci --interval 1
same "the statuses API keeps failing: exit 3 after 3 reads, gh's error kept" \
  "3||3" "$rc|$out|$(calls '/status\?')"
same "its error names gh's message" "gh: Server Error (HTTP 500)${nl}Could not read the checks of $SHA" "$errout"
fresh; checks "$SHA" 1 build completed success; echo 'check-runs' >"$FX/fail-once"
ci --interval 1
same "a failed read is retried at the next poll" "0|green|2" "$rc|$out|$(calls check-runs)"
fresh; checks "$SHA" 1 build completed success; echo 'check-runs' >"$FX/fail"
ci --timeout 0
same "a failed read with no time left: exit 3" "3|" "$rc|$out"

echo "• octo-merge.sh"
merge() { run octo-merge.sh --repo o/n --pr 7 --sha "$SHA"; }

fresh; pr 7
merge
same "200: merged with a regular merge commit, then the branch deleted" \
  "0|merged m7${nl}deleted branch 7-x" "$rc|$out"
same "merge_method=merge and the reviewed sha, raw; then the head branch's ref" \
  "MERGE 7 raw:merge_method=merge raw:sha=$SHA${nl}DELETE 7-x" "$writes"
same "the merge is read back" 1 "$(calls "^api repos/o/n/pulls/7 --jq \[\.merged")"
same "the branch is gone" "" "$(cat "$FX/branches")"

fresh; pr 7 "feature/a#b c"
merge
same "a branch with a slash and special characters: its ref path is encoded per segment" \
  "0|merged m7${nl}deleted branch feature/a#b c|DELETE feature/a#b c" "$rc|$out|$(sed -n 2p "$FX/writes")"
same "the encoded path went to GitHub" 1 "$(calls '^api -X DELETE repos/o/n/git/refs/heads/feature/a%23b%20c$')"

fresh; pr 7 7-x o/n "$OTHER"
merge
same "409, the head moved past the reviewed commit: not merged, no delete" \
  "1|not merged: head moved: gh: Head branch was modified. Review and try the merge again. (HTTP 409)|0" \
  "$rc|$out|$(grep -c DELETE <<<"$writes")"

fresh; pr 7; echo 405 >"$FX/merge/7"
merge
same "405: not mergeable, not merged, no delete" \
  "1|not merged: not mergeable: gh: Pull Request is not mergeable (HTTP 405)|0" \
  "$rc|$out|$(grep -c DELETE <<<"$writes")"

fresh; pr 7; echo 500 >"$FX/merge/7"
merge
same "another error, and the PR not merged: not merged, gh's error" \
  "1|not merged: gh: Server Error (HTTP 500)" "$rc|$out"

fresh; pr 7; echo 500-merged >"$FX/merge/7"
merge
same "the call failed but the merge landed: merged (the read-back decides), warned, branch deleted" \
  "0|merged m7${nl}warn: the merge call failed, but the PR merged: gh: Server Error (HTTP 500)${nl}deleted branch 7-x" \
  "$rc|$out"

fresh; pr 7; echo 500 >"$FX/merge/7"; touch "$FX/fail-after-merge"
merge
same "the call and the read-back both fail: exit 3, merge state unknown" "3|" "$rc|$out"

fresh; pr 7; touch "$FX/fail-after-merge"
merge
same "a 200 and a failed read-back: merged, by the merge call's own answer" \
  "0|merged m7${nl}deleted branch 7-x" "$rc|$out"

fresh; pr 7; touch "$FX/lag"
merge
same "a 200 with merged:true and a read-back that lags: merged, by the merge call, branch deleted" \
  "0|merged m7${nl}deleted branch 7-x" "$rc|$out"

fresh; pr 7; touch "$FX/delete-403"
merge
same "the branch delete 403s (the cloud proxy): merged, a warning, exit 0" \
  "0|merged m7${nl}warn: branch 7-x not deleted: gh: Forbidden (HTTP 403)" "$rc|$out"

fresh; pr 7; : >"$FX/branches"
merge
same "the branch already deleted (422, the repo's own setting): merged, said so" \
  "0|merged m7${nl}branch 7-x already deleted" "$rc|$out"

fresh; pr 7 7-x other/n
merge
same "a fork's branch is never deleted" \
  "0|merged m7${nl}kept branch 7-x: it is in another repo (other/n)|0" \
  "$rc|$out|$(grep -c DELETE <<<"$writes")"
fresh; pr 7 7-x null
merge
same "a deleted fork's branch is never deleted" \
  "0|merged m7${nl}kept branch 7-x: its repo was deleted (a fork)|0" \
  "$rc|$out|$(grep -c DELETE <<<"$writes")"
fresh; pr 7 7-x O/N
merge
same "the repo's own branch in another case is deleted" "0|merged m7${nl}deleted branch 7-x" "$rc|$out"
fresh; pr 7 main
merge
same "the default branch is never deleted" \
  "0|merged m7${nl}kept branch main: it is the default branch|0" \
  "$rc|$out|$(grep -c DELETE <<<"$writes")"

fresh
merge
same "an unreadable PR: not merged, no merge call" \
  "1|not merged: gh: Not Found (HTTP 404)|" "$rc|$out|$writes"

echo "• REST only"
same "no helper call in this suite was rejected" "" "$(cat "$ALL_REJECTED" 2>/dev/null)"
same "every helper call was gh api repos/o/n/..." "" \
  "$(grep -Ev '^api (-X [A-Z]+ |--paginate )?repos/o/n/' "$ALL_LOG")"
[ "$(wc -l <"$ALL_LOG")" -gt 50 ] && ok "the suite made helper calls" || no "the suite made helper calls"

echo
echo "merge-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
