#!/usr/bin/env bash
# rest.sh — offline tests for the REST-only issue, label, and sub-issue helpers.
#
# Usage:
#   bash scripts/test/rest.sh
#
# Runs octo-subissue.sh, octo-labels.sh, octo-issue-find.sh, and octo-ledger-read.sh against a
# stub `gh` that plays a small GitHub over REST only: it serves `gh api repos/...` from fixture
# files (issues, labels, comments), applies the writes, and rejects `gh api graphql` and every
# porcelain command (`gh issue`, `gh label`, ...) with the Claude Code cloud proxy's 403, as a
# cloud session does. A list endpoint is served two items a page, and only its first page
# without --paginate, running the --jq filter once per page as gh does. Covers: bad arguments
# (exit 2, no gh call); the sub-issue link by the child's numeric id sent typed, an unreadable
# epic or child, and a refused link (gh's error kept); labels created with their colors and
# descriptions, an existing one (any case) left alone, a failed create that doesn't stop the
# rest, and names sent as raw strings; the open-issue text match (case ignored, plain string,
# pull requests and closed issues left out, every page read) and a gh error; and the ledger's
# newest allowed entries, the skipped count by author association, exact bodies, an empty
# ledger, and a gh error. No call is ever rejected.
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
# bounded <seconds> <command...> : SIGALRM-kill a hung command (macOS has no `timeout`).
bounded() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }

command -v jq >/dev/null || { echo "rest: jq is required for the stub gh" >&2; exit 1; }
# No `set -e`: bail out explicitly, or an empty $tmp would point the stub at the real checkout.
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "rest: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# The stub's state lives in $FX: issues/<n>.json (served as is), labels/<lowercased name> (the
# repo's labels), comments/<n>.json (an issue's comments, a JSON array), sub-error (a message:
# the sub-issue POST answers it as a 422), and fail (an ERE matched against "<METHOD> <endpoint>"
# → a 500). It logs every call to log and $ALL_LOG, every rejected one to $ALL_REJECTED, and
# every write to writes, each field as raw:<k=v> (-f) or typed:<k=v> (-F). Like gh, it prints an
# error's body on stdout.
stub="$tmp/bin"
FX="$tmp/fx"
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
# One log line per call, even with a multi-line --jq filter.
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
    --silent) shift ;;
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
# field <name> : the value of the field <name>, from either flag.
field() { printf '%s\n' "$fields" | sed -n "s/^[a-z]*:$1=//p"; }
# logged : the fields on one line, as " raw:k=v typed:k=v".
logged() { printf '%s' "$fields" | tr '\n' ' '; }
# pages : serve the JSON array on stdin two items a page (one page without --paginate), running
# the --jq filter on each page, as gh does.
pages() {
  local all n i=0
  all=$(cat); n=$(jq length <<<"$all")
  while :; do
    jq -c ".[$i:$((i + 2))]" <<<"$all" | jq -r "$jq" || exit 9
    i=$((i + 2))
    [ "$paginate" -eq 1 ] && [ "$i" -lt "$n" ] || break
  done
}
case "$method $ep" in
  "GET repos/o/n/issues?state=open&sort=created&direction=asc&per_page=100")
    cat "$FX"/issues/*.json 2>/dev/null |
      jq -s 'map(select(.state == "open")) | sort_by(.number)' | pages ;;
  "GET repos/o/n/issues/"*"/comments?per_page=100")
    n=${ep%/comments*}; n=${n##*/}; f="$FX/comments/$n.json"
    [ -f "$f" ] || err 404 "Not Found"; pages <"$f" ;;
  "GET repos/o/n/issues/"*)
    f="$FX/issues/${ep##*/}.json"; [ -f "$f" ] || err 404 "Not Found"; jq -r "$jq" <"$f" ;;
  "POST repos/o/n/issues/"*/sub_issues)
    n=${ep%/sub_issues}; n=${n##*/}
    [ ! -s "$FX/sub-error" ] || err 422 "$(cat "$FX/sub-error")"
    echo "LINK $n$(logged)" >>"$FX/writes"; jq -r "$jq" <"$FX/issues/$n.json" ;;
  "POST repos/o/n/labels")
    name=$(field name); key=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    if [ -e "$FX/labels/$key" ]; then
      echo '{"message":"Validation Failed","errors":[{"resource":"Label","code":"already_exists","field":"name"}],"status":"422"}'
      echo "gh: Validation Failed (HTTP 422)" >&2; exit 1
    fi
    touch "$FX/labels/$key"; echo "LABEL$(logged)" >>"$FX/writes"
    jq -n --arg n "$name" '{name: $n}' | jq -r "$jq" ;;
  *) echo "stub: unexpected $method $ep" >&2; exit 9 ;;
esac
STUB
chmod +x "$stub/gh"
ALL_LOG="$tmp/all-log" ALL_REJECTED="$tmp/all-rejected"
export FX ALL_LOG ALL_REJECTED

# fresh : an empty GitHub.
fresh() { rm -rf "$FX"; mkdir -p "$FX/issues" "$FX/labels" "$FX/comments"; }
# issue <n> <state> [title [body [is-pr]]] : write issues/<n>.json, its id 1000 + n.
issue() {
  jq -n --argjson n "$1" --arg s "$2" --arg t "${3:-Issue $1}" --arg b "${4:-}" --arg pr "${5:-}" \
    '{id: (1000 + $n), number: $n, state: $s, title: $t, body: $b,
      html_url: "https://github.com/o/n/issues/\($n)"}
     + (if $pr == "" then {} else {pull_request: {url: "x"}} end)' >"$FX/issues/$1.json"
}
# run <helper> [args...] : the helper against the stub; sets out (stdout), errout, rc, writes.
run() {
  local h="$SCRIPTS_DIR/$1"; shift
  out="$(PATH="$stub:$PATH" bounded 20 bash "$h" "$@" 2>"$tmp/stderr")"
  rc=$?
  errout="$(cat "$tmp/stderr")"
  writes="$(cat "$FX/writes" 2>/dev/null)"
}
nl=$'\n' tab=$'\t'

echo "• the stub rejects GraphQL and porcelain, as the cloud proxy does"
fresh
o="$(PATH="$stub:$PATH" gh api graphql -f query='{viewer{login}}' 2>&1)"; r=$?
same "gh api graphql is refused with the proxy's 403" \
  "1|gh: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). (HTTP 403)" \
  "$r|$o"
PATH="$stub:$PATH" gh label create epic --repo o/n >/dev/null 2>&1
same "gh label is refused too" 1 "$?"
PATH="$stub:$PATH" gh issue list --repo o/n >/dev/null 2>&1
same "gh issue is refused too" 1 "$?"
rm -f "$ALL_LOG" "$ALL_REJECTED"

echo "• bad arguments (exit 2, no gh call)"
fresh
while IFS='|' read -r helper args; do
  # shellcheck disable=SC2086 # each case is several words on purpose
  o="$(PATH="$stub:$PATH" bounded 10 bash "$SCRIPTS_DIR/$helper" $args 2>/dev/null)"; r=$?
  same "$helper ${args:-(no arguments)} exits 2" "2|" "$r|$o"
done <<'CASES'
octo-subissue.sh|
octo-subissue.sh|--repo o/n --parent 1
octo-subissue.sh|--repo o/n --parent x --child 2
octo-subissue.sh|--repo o/n --parent 1 --child 02
octo-subissue.sh|--repo o/n --parent 1/../2 --child 3
octo-subissue.sh|--repo on --parent 1 --child 2
octo-subissue.sh|--repo o/n/x --parent 1 --child 2
octo-labels.sh|
octo-labels.sh|--repo o/n
octo-labels.sh|epic
octo-labels.sh|--repo o?x/n epic
octo-labels.sh|--repo o/n --color fff epic
octo-issue-find.sh|--repo o/n
octo-issue-find.sh|--text x
octo-issue-find.sh|--repo /n --text x
octo-ledger-read.sh|--repo o/n
octo-ledger-read.sh|--repo o/n --issue 0
octo-ledger-read.sh|--repo o/n --issue 3 --last 0
octo-ledger-read.sh|--repo o/n --issue 3 --last x
CASES
run octo-issue-find.sh --repo o/n --text "two${nl}lines"
same "octo-issue-find.sh: a --text with a line break exits 2" 2 "$rc"
run octo-labels.sh --repo o/n "bad${nl}name"
same "octo-labels.sh: a name with a line break exits 2" 2 "$rc"
run octo-labels.sh --repo o/n epic ""
same "octo-labels.sh: an empty name exits 2" 2 "$rc"
same "no gh call for bad arguments" "" "$(cat "$FX/log" 2>/dev/null)"

echo "• octo-subissue.sh"
fresh; issue 10 open; issue 11 open
run octo-subissue.sh --repo o/n --parent 10 --child 11
same "links the child by its numeric id, sent typed (-F)" \
  "0|Linked #11 as sub-issue of #10|LINK 10 typed:sub_issue_id=1011" "$rc|$out|$writes"

fresh; issue 11 open
run octo-subissue.sh --repo o/n --parent 10 --child 11
same "an unreadable epic: exit 1, gh's error, then the script's, no link" \
  "1|gh: Not Found (HTTP 404)${nl}Could not resolve epic #10|" "$rc|$errout|$writes"

fresh; issue 10 open
run octo-subissue.sh --repo o/n --parent 10 --child 11
same "an unreadable child: exit 1, gh's error, then the script's, no link" \
  "1|gh: Not Found (HTTP 404)${nl}Could not resolve child #11|" "$rc|$errout|$writes"

fresh; issue 10 open; issue 11 open; echo "Issue may not contain duplicate sub-issues" >"$FX/sub-error"
run octo-subissue.sh --repo o/n --parent 10 --child 11
same "a refused link: exit 1, with gh's error and the fallback hint" \
  "1|Sub-issue link failed for #11 -> #10: gh: Issue may not contain duplicate sub-issues (HTTP 422)${nl}Caller should fall back to a task-list entry." \
  "$rc|$errout"

echo "• octo-labels.sh"
fresh
run octo-labels.sh --repo o/n epic p2 needs-approval "good first issue"
same "creates each missing label" \
  "0|created epic${nl}created p2${nl}created needs-approval${nl}created good first issue" "$rc|$out"
same "with the conventions' colors and descriptions, as raw strings (-f)" \
  "LABEL raw:name=epic raw:color=6f42c1 raw:description=Large body of work" \
  "$(sed -n 1p "$FX/writes")"
same "a priority label has no description" "LABEL raw:name=p2 raw:color=ededed raw:description=" \
  "$(sed -n 2p "$FX/writes")"
same "an unknown label gets ededed and no description" \
  "LABEL raw:name=good first issue raw:color=ededed raw:description=" "$(sed -n 4p "$FX/writes")"

fresh; touch "$FX/labels/bug"
run octo-labels.sh --repo o/n Bug feature
same "an existing label (any case) is left alone" \
  "0|exists Bug${nl}created feature" "$rc|$out"
same "only the missing label is written" 1 "$(wc -l <"$FX/writes" | tr -d ' ')"

fresh; echo '^POST repos/o/n/labels$' >"$FX/fail"
run octo-labels.sh --repo o/n ready proposed
same "a failed create: exit 1, and every label is still tried" \
  "1|failed ready: gh: Server Error (HTTP 500)${nl}failed proposed: gh: Server Error (HTTP 500)" \
  "$rc|$out"

fresh
run octo-labels.sh --repo o/n @team 123
same "a name starting with @ or a digit is sent as a raw string" \
  "0|LABEL raw:name=@team raw:color=ededed raw:description=${nl}LABEL raw:name=123 raw:color=ededed raw:description=" \
  "$rc|$writes"

echo "• octo-issue-find.sh"
T='it("parses [x] \"quoted\"")'
fresh
issue 1 open "Flaky test: $T"
issue 2 open "Something else" "Seen again:${nl}IT(\"PARSES [X] \\\"QUOTED\\\"\") failed"
issue 3 closed "Flaky test: $T"
issue 4 open "Fix $T" "" pr
issue 5 open "Unrelated"
issue 6 open "Third page" "the same $T"
run octo-issue-find.sh --repo o/n --text "$T"
same "matches title or body, ignoring case, on every page; no PR, no closed issue" \
  "0|1 https://github.com/o/n/issues/1${nl}2 https://github.com/o/n/issues/2${nl}6 https://github.com/o/n/issues/6" \
  "$rc|$out"
same "it read every page" 1 "$(grep -c -- '--paginate' "$FX/log")"

run octo-issue-find.sh --repo o/n --text 'Flaky.*parses'
same "the text is a plain string, not a pattern" "0|none" "$rc|$out"

run octo-issue-find.sh --repo o/n --text "seen again: it("
same "a line break in an issue counts as a space" "0|2 https://github.com/o/n/issues/2" "$rc|$out"

fresh; issue 4 open "Fix it" "" pr
run octo-issue-find.sh --repo o/n --text "Fix it"
same "no open issue matches: none" "0|none" "$rc|$out"

fresh; issue 1 open "x"; echo 'issues\?state=open' >"$FX/fail"
run octo-issue-find.sh --repo o/n --text x
same "a gh error: exit 1, nothing printed" "1|" "$rc|$out"

echo "• octo-ledger-read.sh"
# comment <user-assoc> <body> : one comment object.
comment() {
  jq -n --arg a "$1" --arg b "$2" --arg id "$3" \
    '{html_url: "https://github.com/o/n/issues/3#issuecomment-\($id)", created_at: "2026-11-0\($id)T00:00:00Z",
      author_association: $a, body: $b}'
}
E1='Run 1.'"$nl$nl"'```json'"$nl"'{"kind": "run"}'"$nl"'```'
E2="Run 2 with a tab${tab}and \"quotes\" and a backslash \\ ${nl}\`\`\`json${nl}{}${nl}\`\`\`"
E3='Run 3.'"$nl"'```json'"$nl"'{"kind": "observe"}'"$nl"'```'
fresh
{ comment OWNER "$E1" 1; comment NONE "$E1" 2; comment MEMBER "chat, no entry" 3
  comment COLLABORATOR "$E2" 4; comment CONTRIBUTOR "$E3" 5; comment NONE "$E3" 6
  comment OWNER "$E3" 7; } | jq -s . >"$FX/comments/3.json"
run octo-ledger-read.sh --repo o/n --issue 3
same "exit 0, and the output is JSON" "0|object" "$rc|$(jq -r type <<<"$out" 2>&1)"
same "the entries from allowed authors, oldest first, newest last" \
  "1 OWNER|4 COLLABORATOR|7 OWNER" \
  "$(jq -r '[.entries[] | "\(.url | sub(".*-"; "")) \(.authorAssociation)"] | join("|")' <<<"$out")"
same "skipped counts the other authors' entry-shaped comments" "1 (CONTRIBUTOR), 2 (NONE)" \
  "$(jq -r .skipped <<<"$out")"
same "a body comes back exactly (tab, quotes, backslash, newlines)" "$E2" \
  "$(jq -r '.entries[1].body' <<<"$out")"
same "entries keep the old keys" "authorAssociation,body,createdAt,url" \
  "$(jq -r '.entries[0] | keys | join(",")' <<<"$out")"

run octo-ledger-read.sh --repo o/n --issue 3 --last 2
same "--last keeps the newest N" "4|7" \
  "$(jq -r '[.entries[] | .url | sub(".*-"; "")] | join("|")' <<<"$out")"

fresh; echo '[]' >"$FX/comments/3.json"
run octo-ledger-read.sh --repo o/n --issue 3
same "an empty ledger" '0|{"skipped":"","entries":[]}' "$rc|$out"

fresh
run octo-ledger-read.sh --repo o/n --issue 3
same "an unreadable ledger: exit 1, nothing printed" "1|" "$rc|$out"

echo "• REST only"
same "no helper call in this suite was rejected" "" "$(cat "$ALL_REJECTED" 2>/dev/null)"
same "every helper call was gh api repos/o/n/..." "" "$(grep -Ev '^api repos/o/n/' "$ALL_LOG")"
[ "$(wc -l <"$ALL_LOG")" -gt 20 ] && ok "the suite made helper calls" || no "the suite made helper calls"

echo
echo "rest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
