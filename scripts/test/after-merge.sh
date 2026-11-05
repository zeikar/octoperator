#!/usr/bin/env bash
# after-merge.sh — offline tests for octo-after-merge.sh, auto's housekeeping after a merge.
#
# Usage:
#   bash scripts/test/after-merge.sh
#
# Runs the helper against a stub `gh` that plays a small GitHub over REST only: it serves
# `gh api repos/...` from fixture files (issues, the PR, parents, sub-issues), applies PATCHes
# and comments to them, and rejects `gh api graphql` and every porcelain command (`gh issue`,
# `gh pr`, ...) with the Claude Code cloud proxy's 403, as a cloud session does. Covers: bad
# arguments (exit 2, no gh call; a non-numeric or overlong --issue too), no --issue (nothing to
# close, no gh call), an --issue already closed (nothing to close), an open one closed with its
# comment, one GitHub closes during the wait, an --issue that is a pull request (never closed), a
# PR that is not merged or not into the default branch, the last child closing its epic
# (sub-issue or `## Children` list item: checkbox, plain bullet, or numbered), an epic kept for
# an open child (either kind), a checklist #N not covered by another repo's sub-issue #N, an item
# naming no issue, zero children, a missing `epic` label, or a parent in another repo, no parent,
# and API failures (each a `warn:` line and exit 0, never a close on missing data; a bare 404 on
# the parent or sub-issue endpoint is one too). No call is ever rejected.
#
# Nothing here calls the real gh or the network. Exits 0 when every check passes, 1 when any fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
HELPER="$SCRIPTS_DIR/octo-after-merge.sh"

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

command -v jq >/dev/null || { echo "after-merge: jq is required for the stub gh" >&2; exit 1; }
# No `set -e`: bail out explicitly, or an empty $tmp would point the stub at the real checkout.
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "after-merge: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# The stub's state lives in $FX: issues/<n>.json and pulls/<n>.json (served as is), parent/<n>
# (the parent's number; none → gh's "No parent issue found" 404), subs/<e> (the sub-issue
# file names, served from those issue files; none → []), no-sub-api and no-parent-api (that
# endpoint → a bare 404, as where the API is missing), closes-after/<n> (GitHub closes #n on that read), and fail (an ERE
# matched against "<METHOD> <endpoint>" → a 500). It logs every call to log and to $ALL_LOG,
# every rejected one to $ALL_REJECTED, and every write to writes. Like gh, it prints an error's
# body on stdout.
stub="$tmp/bin"
FX="$tmp/fx"
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/log"; echo "$*" >>"$ALL_LOG"
reject() {
  echo "$*" >>"$ALL_REJECTED"
  echo 'gh: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). (HTTP 403)' >&2
  exit 1
}
[ "${1:-}" = api ] || reject "$@"
shift
method="" ep="" jq="." fields=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X | --method) method="$2"; shift 2 ;;
    --jq) jq="$2"; shift 2 ;;
    -f | -F | --raw-field | --field) fields="$fields"$'\n'"$2"; shift 2 ;;
    -H | --header) shift 2 ;;
    --paginate | --silent) shift ;;
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
out() { jq -r "$jq"; }
field() { printf '%s\n' "$fields" | sed -n "s/^$1=//p"; }
case "$method $ep" in
  "GET repos/o/n/pulls/"*)
    f="$FX/pulls/${ep##*/}.json"; [ -f "$f" ] || err 404 "Not Found"; out <"$f" ;;
  "GET repos/o/n/issues?labels=epic&state=open&per_page=100")
    cat "$FX"/issues/*.json |
      jq -s '[.[] | select(.state == "open" and any(.labels[]; .name == "epic"))]' | out ;;
  "GET repos/o/n/issues/"*/parent)
    [ ! -e "$FX/no-parent-api" ] || err 404 "Not Found"
    n=${ep%/parent}; n=${n##*/}
    [ -f "$FX/parent/$n" ] || err 404 "No parent issue found"
    out <"$FX/issues/$(cat "$FX/parent/$n").json" ;;
  "GET repos/o/n/issues/"*"/sub_issues?per_page=100")
    [ ! -e "$FX/no-sub-api" ] || err 404 "Not Found"
    e=${ep%/sub_issues*}; e=${e##*/}
    for c in $(cat "$FX/subs/$e" 2>/dev/null); do cat "$FX/issues/$c.json"; done | jq -s . | out ;;
  "GET repos/o/n/issues/"*)
    n=${ep##*/}; f="$FX/issues/$n.json"; [ -f "$f" ] || err 404 "Not Found"
    reads=$(( $(cat "$FX/reads-$n" 2>/dev/null || echo 0) + 1 )); echo "$reads" >"$FX/reads-$n"
    if [ "$(cat "$FX/closes-after/$n" 2>/dev/null)" = "$reads" ]; then
      jq '.state = "closed"' "$f" >"$f.new" && mv "$f.new" "$f"
    fi
    out <"$f" ;;
  "PATCH repos/o/n/issues/"*)
    n=${ep##*/}; f="$FX/issues/$n.json"; [ -f "$f" ] || err 404 "Not Found"
    echo "PATCH $n state=$(field state) state_reason=$(field state_reason)" >>"$FX/writes"
    jq --arg s "$(field state)" '.state = $s' "$f" >"$f.new" && mv "$f.new" "$f" ;;
  "POST repos/o/n/issues/"*/comments)
    n=${ep%/comments}; n=${n##*/}
    echo "COMMENT $n $(field body)" >>"$FX/writes" ;;
  *) echo "stub: unexpected $method $ep" >&2; exit 9 ;;
esac
STUB
chmod +x "$stub/gh"
ALL_LOG="$tmp/all-log" ALL_REJECTED="$tmp/all-rejected"
export FX ALL_LOG ALL_REJECTED

# fresh : an empty GitHub.
fresh() { rm -rf "$FX"; mkdir -p "$FX/issues" "$FX/pulls" "$FX/parent" "$FX/subs" "$FX/closes-after"; }
# issue <n> <state> [labels-json [body [repo]]] : write issues/<n>.json.
issue() {
  jq -n --argjson n "$1" --arg s "$2" --argjson l "${3:-[]}" --arg b "${4:-}" \
    --arg r "https://api.github.com/repos/${5:-o/n}" \
    '{number: $n, state: $s, labels: ($l | map({name: .})), body: $b, repository_url: $r}' \
    >"$FX/issues/$1.json"
}
EPIC='["epic","p1"]'
# pr [merged [base [default]]] : write pulls/10.json, the merged PR every run reads.
pr() {
  jq -n --argjson m "${1:-true}" --arg base "${2:-main}" --arg d "${3:-main}" \
    '{number: 10, merged: $m, base: {ref: $base, repo: {default_branch: $d}}}' \
    >"$FX/pulls/10.json"
}
# run [args...] : the helper on PR #10 and issue #5 with no wait; sets out / rc / writes.
run() {
  out="$(PATH="$stub:$PATH" bounded 20 bash "$HELPER" --repo o/n --pr 10 --issue 5 --interval 0 "$@" 2>&1)"
  rc=$?
  writes="$(cat "$FX/writes" 2>/dev/null)"
}
nl=$'\n'

echo "• the stub rejects GraphQL and porcelain, as the cloud proxy does"
fresh
o="$(PATH="$stub:$PATH" gh api graphql -f query='{viewer{login}}' 2>&1)"; r=$?
same "gh api graphql is refused with the proxy's 403" \
  "1|gh: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). (HTTP 403)" \
  "$r|$o"
o="$(PATH="$stub:$PATH" gh issue close 5 --repo o/n 2>&1)"; r=$?
same "gh issue is refused too" 1 "$r"
o="$(PATH="$stub:$PATH" gh pr view 10 --repo o/n 2>&1)"; r=$?
same "gh pr is refused too" 1 "$r"
rm -f "$ALL_LOG" "$ALL_REJECTED"

echo "• bad arguments (exit 2, no gh call)"
fresh
for args in "" "--repo o/n" "--pr 10" "--repo o/n --pr x" "--repo o/n --pr 0" "--repo on --pr 10" \
  "--repo o/n/x --pr 10" "--repo o/n --pr 10 --tries 0" "--repo o/n --pr 10 --interval -1" \
  "--repo o/n --pr 10 --bogus" "--repo o/n --pr" "--repo o/n --pr 10 --issue" \
  "--repo o/n --pr 10 --issue x" "--repo o/n --pr 10 --issue 0" "--repo o/n --pr 10 --issue -5" \
  "--repo o/n --pr 10 --issue 05" "--repo o/n --pr 10 --issue 1234567890" \
  "--repo o/n --pr 10 --issue 99999999999999999999"; do
  # shellcheck disable=SC2086 # each case is several words on purpose
  o="$(PATH="$stub:$PATH" bounded 10 bash "$HELPER" $args 2>/dev/null)"; r=$?
  same "${args:-no arguments} exits 2" "2|" "$r|$o"
done
same "no gh call for bad arguments" "" "$(cat "$FX/log" 2>/dev/null)"

echo "• no --issue (auto's --pr path)"
fresh; pr; issue 5 open
o="$(PATH="$stub:$PATH" bounded 20 bash "$HELPER" --repo o/n --pr 10 --interval 0 2>&1)"; r=$?
same "nothing to close, exit 0" "0|nothing to close" "$r|$o"
same "no gh call, so no write and no epic check" "" "$(cat "$FX/log" 2>/dev/null)"

echo "• the --issue"
fresh; pr; issue 5 closed
run
same "already closed (GitHub closed it): nothing to close, no write" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 5 open
run --tries 1
same "open: closed as completed, with a comment naming the PR" \
  "0|closed issue #5|PATCH 5 state=closed state_reason=completed${nl}COMMENT 5 Closed by #10 (merged)" \
  "$rc|$out|$writes"
same "the issue reads closed afterwards" closed "$(jq -r .state "$FX/issues/5.json")"

fresh; pr; issue 5 open; echo 2 >"$FX/closes-after/5"
run --tries 3
same "GitHub closes it during the wait: nothing to close, no write" "0|nothing to close|" \
  "$rc|$out|$writes"

fresh; pr; issue 5 open
run --tries 3
same "still open after every try: closed" "0|closed issue #5" "$rc|$out"
same "it read the issue --tries times before closing" 3 "$(cat "$FX/reads-5")"

fresh; pr; issue 5 open
jq '. + {pull_request: {url: "x"}}' "$FX/issues/5.json" >"$FX/x" && mv "$FX/x" "$FX/issues/5.json"
run --tries 1
same "an --issue that is a pull request is never closed" \
  "0|warn: #5 is a pull request; nothing closed|" "$rc|$out|$writes"

fresh; pr false; issue 5 open
run --tries 1
same "an unmerged PR: a warning, exit 0, no write" \
  "0|warn: PR #10 is not merged; nothing closed|" "$rc|$out|$writes"

fresh; pr true release main; issue 5 open
run --tries 1
same "a PR into another branch closes nothing (GitHub closes only from the default branch)" \
  "0|nothing to close|" "$rc|$out|$writes"

echo "• the epic: sub-issues"
fresh; pr; issue 2 open "$EPIC"; issue 5 open; issue 6 closed
echo 2 >"$FX/parent/5"; echo "5 6" >"$FX/subs/2"
run --tries 1
same "last child: the issue and its epic close" \
  "0|closed issue #5${nl}closed epic #2" "$rc|$out"
same "the epic's comment names the merged PR" \
  "COMMENT 2 All children of this epic are closed; closed after #10 merged." \
  "$(grep '^COMMENT 2 ' "$FX/writes")"
same "the epic closed as completed" "PATCH 2 state=closed state_reason=completed" \
  "$(grep '^PATCH 2 ' "$FX/writes")"

fresh; pr; issue 2 open "$EPIC"; issue 5 closed; issue 6 closed
echo 2 >"$FX/parent/5"; echo "5 6" >"$FX/subs/2"
run
same "GitHub closed the issue: the epic still closes" "0|closed epic #2" "$rc|$out"

fresh; pr; issue 2 open "$EPIC"; issue 5 closed; issue 7 open
echo 2 >"$FX/parent/5"; echo "5 7" >"$FX/subs/2"
run
same "another child open: the epic is kept" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 2 open "$EPIC"; issue 5 closed; issue 77 open '[]' '' other/repo
echo 2 >"$FX/parent/5"; echo "5 77" >"$FX/subs/2"
run
same "an open sub-issue in another repo is a child too: the epic is kept" \
  "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 2 open "$EPIC"; issue 5 closed
echo 2 >"$FX/parent/5"
run
same "zero children listed: the epic is kept" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 2 open '["feature"]'; issue 5 closed
echo 2 >"$FX/parent/5"; echo 5 >"$FX/subs/2"
run
same "a parent without the epic label is kept" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 2 closed "$EPIC"; issue 5 closed
echo 2 >"$FX/parent/5"; echo 5 >"$FX/subs/2"
run
same "an epic already closed: nothing to close" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 2 open "$EPIC" "" other/repo; issue 5 closed
echo 2 >"$FX/parent/5"; echo 5 >"$FX/subs/2"
run
same "a parent in another repo is left alone" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 5 closed
run
same "no parent and no checklist: nothing to close" "0|nothing to close|" "$rc|$out|$writes"

echo "• the epic: the ## Children list fallback"
CHILDREN="Some request.${nl}${nl}## Children${nl}- [x] #5${nl}- [ ] #6 the other one${nl}${nl}## Acceptance criteria${nl}- [ ] #9"
fresh; pr; issue 3 open "$EPIC" "$CHILDREN"; issue 5 open; issue 6 closed; issue 9 open
run --tries 1
same "last checklist child: the epic closes (a later section's #9 is no child)" \
  "0|closed issue #5${nl}closed epic #3" "$rc|$out"

fresh; pr; issue 3 open "$EPIC" "$CHILDREN"; issue 5 closed; issue 6 open
run
same "another checklist child open: the epic is kept" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 3 open "$EPIC" "## Children${nl}- [x] #5${nl}- #6"; issue 5 closed; issue 6 open
run
same "a plain bullet is a child: open, it keeps the epic" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 3 open "$EPIC" "## Children${nl}1. [x] #5${nl}2. #6"; issue 5 closed; issue 6 open
run
same "a numbered item is a child: open, it keeps the epic" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 3 open "$EPIC" "## Children${nl}1. #5${nl}+ #006 done"; issue 5 closed; issue 6 closed
run
same "numbered and plain items, all closed: the epic closes" "0|closed epic #3" "$rc|$out"

fresh; pr
issue 3 open "$EPIC" "## Children${nl}- [x] #5${nl}- [ ] # API docs, not filed yet"; issue 5 closed
run
same "an item naming no issue keeps the epic open" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 3 open "$EPIC" "## Children${nl}- [x] #5${nl}- API docs (#6)"; issue 5 closed
issue 6 closed
run
same "an item not starting with #N is unknown: the epic is kept" "0|nothing to close|" \
  "$rc|$out|$writes"

fresh; pr
issue 3 open "$EPIC" "$(printf '## children\r\n* [X] #5\r\n')"; issue 5 closed
run
same "CRLF, another heading case, and * [X] still parse" "0|closed epic #3" "$rc|$out"

fresh; pr; issue 3 open "$EPIC" "## Notes${nl}- [ ] #5"; issue 5 closed
run
same "#5 outside ## Children makes no epic" "0|nothing to close|" "$rc|$out|$writes"

fresh; pr; issue 2 open "$EPIC" "## Children${nl}- [ ] #8"; issue 5 closed; issue 8 open
echo 2 >"$FX/parent/5"; echo 5 >"$FX/subs/2"
run
same "sub-issues and checklist together: an open checklist child keeps it" \
  "0|nothing to close|" "$rc|$out|$writes"

# This repo's #7 is open; the closed sub-issue #7 is other/repo's, so it doesn't cover it.
fresh; pr; issue 2 open "$EPIC" "## Children${nl}- [x] #5${nl}- [ ] #7"; issue 5 closed; issue 7 open
issue 77 closed '[]' '' other/repo
jq '.number = 7' "$FX/issues/77.json" >"$FX/x" && mv "$FX/x" "$FX/issues/77.json"
echo 2 >"$FX/parent/5"; echo "5 77" >"$FX/subs/2"
run
same "a checklist #7 isn't covered by another repo's sub-issue #7: the epic is kept" \
  "0|nothing to close|" "$rc|$out|$writes"

echo "• API failures: a warning, exit 0, nothing closed on missing data"
fresh; pr; issue 5 open; echo '^GET repos/o/n/pulls/10$' >"$FX/fail"
run --tries 1
same "the PR read fails" "0|warn: could not read PR #10: gh: Server Error (HTTP 500)|" \
  "$rc|$out|$writes"

fresh; pr; issue 5 open; echo '^GET repos/o/n/issues/5$' >"$FX/fail"
run --tries 1
same "the issue read fails" "0|warn: could not read #5: gh: Server Error (HTTP 500)|" \
  "$rc|$out|$writes"

fresh; pr; issue 5 open; echo '^PATCH ' >"$FX/fail"
run --tries 1
same "the close fails: no 'closed' line, no comment" \
  "0|warn: could not close #5: gh: Server Error (HTTP 500)|" "$rc|$out|$writes"

fresh; pr; issue 5 open; echo '^POST ' >"$FX/fail"
run --tries 1
same "the comment fails: still closed, with a warning" \
  "0|warn: closed #5 but could not comment: gh: Server Error (HTTP 500)${nl}closed issue #5" \
  "$rc|$out"

fresh; pr; issue 2 open "$EPIC"; issue 5 closed; issue 6 closed
echo 2 >"$FX/parent/5"; echo "5 6" >"$FX/subs/2"; echo 'sub_issues' >"$FX/fail"
run
same "the sub-issue list fails: the epic is kept" \
  "0|warn: could not list the sub-issues of epic #2: gh: Server Error (HTTP 500)|" \
  "$rc|$out|$writes"

fresh; pr; issue 2 open "$EPIC" "## Children${nl}- [x] #5"; issue 5 closed
echo 2 >"$FX/parent/5"; echo 5 >"$FX/subs/2"; touch "$FX/no-sub-api"
run
same "a bare 404 on sub-issues: a warning, and the epic is kept" \
  "0|warn: could not list the sub-issues of epic #2: gh: Not Found (HTTP 404)|" \
  "$rc|$out|$writes"

fresh; pr; issue 2 open "$EPIC"; issue 5 closed
echo 2 >"$FX/parent/5"; echo 5 >"$FX/subs/2"; echo 'labels=epic' >"$FX/fail"
run
same "the epic list fails: no epic closes (its checklist is unknown)" \
  "0|warn: could not list open epics: gh: Server Error (HTTP 500)|" "$rc|$out|$writes"

fresh; pr; issue 3 open "$EPIC" "## Children${nl}- [x] #5"; issue 5 closed
echo '/parent$' >"$FX/fail"
run
same "the parent read fails: a warning, and the checklist still closes its epic" \
  "0|warn: could not read the parent of #5: gh: Server Error (HTTP 500)${nl}closed epic #3" \
  "$rc|$out"

fresh; pr; issue 2 open "$EPIC"; issue 5 closed
echo 2 >"$FX/parent/5"; echo 5 >"$FX/subs/2"; touch "$FX/no-parent-api"
run
same "a bare 404 on the parent is no 'no parent': a warning, and its epic isn't found" \
  "0|warn: could not read the parent of #5: gh: Not Found (HTTP 404)|" "$rc|$out|$writes"

fresh; pr; issue 3 open "$EPIC" "## Children${nl}- [x] #5${nl}- [x] #6"; issue 5 closed
issue 6 closed; echo '^GET repos/o/n/issues/6$' >"$FX/fail"
run
same "a checklist child's read fails: the epic is kept" \
  "0|warn: could not read #6, a child of epic #3: gh: Server Error (HTTP 500)|" "$rc|$out|$writes"

echo "• REST only"
same "no helper call in this suite was rejected" "" "$(cat "$ALL_REJECTED" 2>/dev/null)"
same "every helper call was gh api repos/o/n/..." "" "$(grep -Ev '^api (-X PATCH )?repos/o/n/' "$ALL_LOG")"
[ "$(wc -l <"$ALL_LOG")" -gt 50 ] && ok "the suite made helper calls" || no "the suite made helper calls"

echo
echo "after-merge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
