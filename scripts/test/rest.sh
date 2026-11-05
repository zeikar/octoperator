#!/usr/bin/env bash
# rest.sh — offline tests for the REST-only issue, label, sub-issue, and pull request helpers.
#
# Usage:
#   bash scripts/test/rest.sh
#
# Runs octo-subissue.sh, octo-labels.sh, octo-issue-find.sh, octo-ledger-read.sh, and
# octo-pr-closes.sh against a stub `gh` that plays a small GitHub over REST only: it serves
# `gh api repos/...` from fixture files (issues, labels, comments, pull requests with their
# files, reviews, review comments, and diff), applies the writes, and rejects `gh api graphql` and
# every porcelain command (`gh issue`, `gh label`, `gh pr`, ...) with the Claude Code cloud
# proxy's 403, as a cloud session does. A list endpoint is served two items a page, and only its first page
# without --paginate, running the --jq filter once per page as gh does. Covers: bad arguments
# (exit 2, no gh call); the sub-issue link by the child's numeric id sent typed, an unreadable
# epic or child, and a refused link (gh's error kept); labels created with their colors and
# descriptions, an existing one (any case) left alone, a failed create that doesn't stop the
# rest, and names sent as raw strings; the open-issue text match (case ignored, plain string,
# pull requests and closed issues left out, every page read) and a gh error; and the ledger's
# newest allowed entries, the skipped count by author association, exact bodies, an empty
# ledger, and a gh error; the issues a PR's body closes (every keyword form and case, another
# repo's and a URL's, a negated keyword counted, fenced and inline code and HTML comments
# skipped, an unclosed fence or comment, CRLF, a null body), the PR lists by state (every page,
# oldest first) and --limit (one page, newest-updated first), and a gh error; a body sent on
# stdin by the cookbook's own heredoc recipes (an issue, a comment, a PATCH, a pull request, a
# review), arriving byte for byte with nothing run, and its PR read recipes; and the cookbook's
# label table against octo-labels.sh and every raw label create in the docs. No call is ever
# rejected.
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
# repo's labels), comments/<n>.json (an issue's comments, a JSON array), pulls/<n>.json (a pull
# request), prlists/<n>.<files|reviews|comments>.json (its lists, JSON arrays), prlists/<n>.diff
# (its diff, for `Accept: application/vnd.github.diff`), sub-error (a message:
# the sub-issue POST answers it as a 422), and fail (an ERE matched against "<METHOD> <endpoint>"
# → a 500). It logs every call to log and $ALL_LOG, every rejected one to $ALL_REJECTED, and
# every write to writes, each field as raw:<k=v> (-f) or typed:<k=v> (-F); a `-F k=@-` field's
# stdin goes byte for byte to stdin.<n>, numbered by call. Like gh, it prints an error's body on
# stdout.
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
method="" ep="" jq="." paginate=0 fields="" accept=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X | --method) method="$2"; shift 2 ;;
    -H | --header)
      case "$2" in "Accept: "*) accept="${2#Accept: }" ;; *) echo "stub: header $2" >&2; exit 9 ;; esac
      shift 2 ;;
    --jq) jq="$2"; shift 2 ;;
    -f | --raw-field) fields="$fields"$'\n'"raw:$2"; shift 2 ;;
    -F | --field)
      # k=@- : the value is stdin, kept byte for byte in stdin.<n>, one file per such call.
      case "$2" in *=@-)
        n=$(find "$FX" -maxdepth 1 -name 'stdin.*' | wc -l | tr -d ' ')
        cat >"$FX/stdin.$((n + 1))" ;;
      esac
      fields="$fields"$'\n'"typed:$2"; shift 2 ;;
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
# pages : serve the JSON array on stdin two items a page, or per_page items when the endpoint
# asks for fewer than 100 (one page without --paginate), running the --jq filter on each page,
# as gh does.
pages() {
  local all n i=0 size=2 pp
  pp=$(printf '%s' "$ep" | sed -n 's/.*[?&]per_page=\([0-9]*\).*/\1/p')
  [ -z "$pp" ] || [ "$pp" -ge 100 ] || size=$pp
  all=$(cat); n=$(jq length <<<"$all")
  while :; do
    jq -c ".[$i:$((i + size))]" <<<"$all" | jq -r "$jq" || exit 9
    i=$((i + size))
    [ "$paginate" -eq 1 ] && [ "$i" -lt "$n" ] || break
  done
}
# query <key> : the value of <key> in the endpoint's query string.
query() { printf '%s' "$ep" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
# next_number : issues and pull requests share one sequence of numbers, as on GitHub.
next_number() { echo $(($(find "$FX/issues" "$FX/pulls" -name '*.json' | wc -l | tr -d ' ') + 1)); }
# pr_list : every pull request in $FX/pulls, as one JSON array.
pr_list() { cat "$FX"/pulls/*.json 2>/dev/null | jq -s .; }
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
  "POST repos/o/n/issues")
    n=$(next_number)
    jq -n --argjson n "$n" --arg t "$(field title)" \
      '{id: (1000 + $n), number: $n, state: "open", title: $t,
        html_url: "https://github.com/o/n/issues/\($n)"}' >"$FX/issues/$n.json"
    echo "ISSUE $n$(logged)" >>"$FX/writes"; jq -r "$jq" <"$FX/issues/$n.json" ;;
  "POST repos/o/n/issues/"*/comments)
    n=${ep%/comments}; n=${n##*/}
    echo "COMMENT $n$(logged)" >>"$FX/writes"
    jq -n --arg n "$n" '{html_url: "https://github.com/o/n/issues/\($n)#issuecomment-1"}' |
      jq -r "$jq" ;;
  "PATCH repos/o/n/issues/"*)
    f="$FX/issues/${ep##*/}.json"; [ -f "$f" ] || err 404 "Not Found"
    echo "PATCH ${ep##*/}$(logged)" >>"$FX/writes"; jq -r "$jq" <"$f" ;;
  "POST repos/o/n/labels")
    name=$(field name); key=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    if [ -e "$FX/labels/$key" ]; then
      echo '{"message":"Validation Failed","errors":[{"resource":"Label","code":"already_exists","field":"name"}],"status":"422"}'
      echo "gh: Validation Failed (HTTP 422)" >&2; exit 1
    fi
    touch "$FX/labels/$key"; echo "LABEL$(logged)" >>"$FX/writes"
    jq -n --arg n "$name" '{name: $n}' | jq -r "$jq" ;;
  "GET repos/o/n/pulls?"*)
    # state open | closed (merged included) | all; sort=created asc or sort=updated desc.
    st=$(query state) sort=$(query sort) dir=$(query direction) hd=$(query head)
    pr_list | jq --arg st "$st" --arg sort "$sort" --arg dir "$dir" --arg hd "${hd#*:}" '
      map(select($st == "all" or .state == $st) | select($hd == "" or .head.ref == $hd))
      | if $sort == "updated" then sort_by(.updated_at) else sort_by(.number) end
      | if $dir == "desc" then reverse else . end' | pages ;;
  "GET repos/o/n/pulls/"*"/files?per_page=100" | "GET repos/o/n/pulls/"*"/reviews?per_page=100" | \
  "GET repos/o/n/pulls/"*"/comments?per_page=100")
    rest=${ep#repos/o/n/pulls/}; n=${rest%%/*}; kind=${rest#*/}; kind=${kind%%\?*}
    f="$FX/prlists/$n.$kind.json"; [ -f "$FX/pulls/$n.json" ] || err 404 "Not Found"
    [ -f "$f" ] || f=/dev/null
    { cat "$f"; echo; } | jq -s 'add // []' | pages ;;
  "GET repos/o/n/pulls/"*)
    n=${ep##*/}; f="$FX/pulls/$n.json"; [ -f "$f" ] || err 404 "Not Found"
    case "$accept" in
      application/vnd.github.diff) cat "$FX/prlists/$n.diff" ;;
      "") jq -r "$jq" <"$f" ;;
      *) echo "stub: accept $accept" >&2; exit 9 ;;
    esac ;;
  "POST repos/o/n/pulls")
    n=$(next_number)
    jq -n --argjson n "$n" --arg t "$(field title)" --arg h "$(field head)" --arg b "$(field base)" \
      --arg d "$(field draft)" \
      '{number: $n, state: "open", merged_at: null, draft: ($d == "true"), title: $t,
        head: {ref: $h}, base: {ref: $b}, html_url: "https://github.com/o/n/pull/\($n)"}' \
      >"$FX/pulls/$n.json"
    echo "PULL $n$(logged)" >>"$FX/writes"; jq -r "$jq" <"$FX/pulls/$n.json" ;;
  "POST repos/o/n/pulls/"*/reviews)
    n=${ep%/reviews}; n=${n##*/}; [ -f "$FX/pulls/$n.json" ] || err 404 "Not Found"
    echo "REVIEW $n$(logged)" >>"$FX/writes"
    jq -n --arg n "$n" '{html_url: "https://github.com/o/n/pull/\($n)#pullrequestreview-1"}' |
      jq -r "$jq" ;;
  "POST repos/o/n/pulls/"*/requested_reviewers)
    n=${ep%/requested_reviewers}; n=${n##*/}; [ -f "$FX/pulls/$n.json" ] || err 404 "Not Found"
    echo "REVIEWERS $n$(logged)" >>"$FX/writes"; jq -r "$jq" <"$FX/pulls/$n.json" ;;
  *) echo "stub: unexpected $method $ep" >&2; exit 9 ;;
esac
STUB
chmod +x "$stub/gh"
ALL_LOG="$tmp/all-log" ALL_REJECTED="$tmp/all-rejected"
export FX ALL_LOG ALL_REJECTED

# fresh : an empty GitHub.
fresh() { rm -rf "$FX"; mkdir -p "$FX/issues" "$FX/labels" "$FX/comments" "$FX/pulls" "$FX/prlists"; }
# issue <n> <state> [title [body [is-pr]]] : write issues/<n>.json, its id 1000 + n.
issue() {
  jq -n --argjson n "$1" --arg s "$2" --arg t "${3:-Issue $1}" --arg b "${4:-}" --arg pr "${5:-}" \
    '{id: (1000 + $n), number: $n, state: $s, title: $t, body: $b,
      html_url: "https://github.com/o/n/issues/\($n)"}
     + (if $pr == "" then {} else {pull_request: {url: "x"}} end)' >"$FX/issues/$1.json"
}
# pr <n> <open|closed|merged> <head> [body ("null": none) [draft [updated day [title]]]] :
# write pulls/<n>.json.
pr() {
  jq -n --argjson n "$1" --arg s "$2" --arg h "$3" --arg b "${4-}" --arg d "${5:-false}" \
    --arg u "${6:-$(printf %02d "$1")}" --arg t "${7:-PR $1}" \
    '{number: $n, state: (if $s == "merged" then "closed" else $s end),
      merged: ($s == "merged"), merged_at: (if $s == "merged" then "2026-10-01T00:00:00Z" else null end),
      draft: ($d == "true"), title: $t, body: (if $b == "null" then null else $b end),
      head: {ref: $h, sha: "sha\($n)", repo: {full_name: "o/n"}}, base: {ref: "main", repo: {full_name: "o/n"}},
      user: {login: "dev"}, updated_at: "2026-10-\($u)T00:00:00Z",
      html_url: "https://github.com/o/n/pull/\($n)"}' >"$FX/pulls/$1.json"
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
PATH="$stub:$PATH" gh pr view 1 --repo o/n >/dev/null 2>&1
same "gh pr is refused too" 1 "$?"
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
octo-pr-closes.sh|
octo-pr-closes.sh|--repo o/n
octo-pr-closes.sh|--pr 5
octo-pr-closes.sh|--repo on --pr 5
octo-pr-closes.sh|--repo o/n --pr 0
octo-pr-closes.sh|--repo o/n --pr 05
octo-pr-closes.sh|--repo o/n --pr 5x
octo-pr-closes.sh|--repo o/n --pr 5 --state open
octo-pr-closes.sh|--repo o/n --pr 5 --limit 3
octo-pr-closes.sh|--repo o/n --state merged
octo-pr-closes.sh|--repo o/n --state open --limit 0
octo-pr-closes.sh|--repo o/n --state open --limit 101
octo-pr-closes.sh|--repo o/n --state open --limit 1x
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

echo "• octo-pr-closes.sh"
B="Closes #3
fixes: O/N#4, resolves other/Repo#9
Resolves https://github.com/o/n/issues/21 and fixed https://github.com/X/y/issues/22
see \`closes #10\` and \`\`fix #11 \` \`\` here
<!-- fixes #12 -->
<!--
fixes #13
-->after: closes #14
\`\`\`sh
fixes #15
\`\`\`
~~~~
\`\`\`
fixes #16
~~~~
> \`\`\`
> fixes #24
> \`\`\`
\`\`\`inline\`\`\` closes #23
This does not close #17, and we won't FIX #18 here.
enclosed #30 prefixes #31 Closes #32abc closes#33 close #0 CLOSED #025 Closes #3"
fresh; pr 7 open 7-x "$B"
run octo-pr-closes.sh --repo o/n --pr 7
same "every keyword form and case, in body order, each once; another repo's lowercased" \
  "0|7${tab}open${tab}false${tab}7-x${tab}3,4,other/repo#9,21,x/y#22,14,23,17,18,25${tab}PR 7" \
  "$rc|$out"
same "one read of the PR" "1|1" "$(wc -l <"$FX/log" | tr -d ' ')|$(grep -c '^api repos/o/n/pulls/7 --jq ' "$FX/log")"

while IFS='|' read -r label body want; do
  fresh; pr 8 open b "$(printf '%b' "$body")"
  run octo-pr-closes.sh --repo o/n --pr 8
  same "$label" "0|$want" "$rc|$(cut -f5 <<<"$out")"
done <<'CASES'
an unclosed fence hides the rest|Fixes #1\n```\nFixes #2|1
a longer fence closes only with as many|````\n```\nFixes #1\n````\nFixes #2|2
a ~~~ fence is not closed by ```|~~~\n```\nFixes #1\n~~~\nFixes #2|2
an unclosed comment hides the rest|Fixes #1 <!-- Fixes #2\nFixes #3|1
a comment and code on one line|`x` <!-- a --> Fixes #4 `Fixes #5`|4
an unmatched backtick is plain text|it`s fixed: Fixes #6|6
CRLF line ends|Closes #7\r\nFixes #8\r\n|7,8
no keyword|Part of #79, see #12|-
an empty body|\c|-
CASES
fresh; pr 9 open b null "" "" "tab${tab}in title"
run octo-pr-closes.sh --repo o/n --pr 9
same "a null body closes nothing, and a tab in the title becomes a space" \
  "0|9${tab}open${tab}false${tab}b${tab}-${tab}tab in title" "$rc|$out"

fresh
pr 1 open 1-a "Closes #11" "" 09; pr 2 merged 2-b "Fixes #12" "" 01; pr 3 closed 3-c "" "" 05
pr 4 open 4-d "Closes #14" true 07; pr 5 open feature/x "" "" 02; pr 6 open 6-f "fixes #1" "" 03
run octo-pr-closes.sh --repo o/n --state open
same "--state open: every open PR, oldest first, every page" \
  "0|1${tab}open${tab}false${tab}1-a${tab}11${tab}PR 1${nl}4${tab}open${tab}true${tab}4-d${tab}14${tab}PR 4${nl}5${tab}open${tab}false${tab}feature/x${tab}-${tab}PR 5${nl}6${tab}open${tab}false${tab}6-f${tab}1${tab}PR 6" \
  "$rc|$out"
same "it asked for every page, oldest first" 1 \
  "$(grep -c 'pulls?state=open&sort=created&direction=asc&per_page=100 --paginate' "$FX/log")"
run octo-pr-closes.sh --repo o/n --state closed
same "--state closed: merged and closed, told apart" \
  "0|2 merged 12|3 closed -" "$rc|$(cut -f1,2,5 <<<"$out" | tr '\t\n' ' |' | sed 's/|$//')"
: >"$FX/log"
run octo-pr-closes.sh --repo o/n --state all --limit 3
same "--limit: the most recently updated, newest first" "0|1 4 3" "$rc|$(cut -f1 <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
same "--limit reads one page of that size" "1|0" \
  "$(grep -c 'pulls?state=all&sort=updated&direction=desc&per_page=3 ' "$FX/log")|$(grep -c -- '--paginate' "$FX/log")"

fresh
run octo-pr-closes.sh --repo o/n --state open
same "no PR: nothing printed, exit 0" "0|" "$rc|$out"
run octo-pr-closes.sh --repo o/n --pr 4
same "an unreadable PR: exit 1, gh's error, nothing printed" \
  "1||gh: Not Found (HTTP 404)${nl}octo-pr-closes: could not read PR #4 in o/n" "$rc|$out|$errout"
pr 1 open a; echo 'pulls\?state=' >"$FX/fail"
run octo-pr-closes.sh --repo o/n --state all
same "a failed list: exit 1, nothing printed" "1|" "$rc|$out"

echo "• bodies go on stdin, by the cookbook's heredoc recipes"
COOKBOOK="$SCRIPTS_DIR/../skills/github-conventions/references/gh-cli-cookbook.md"
# recipe <ERE> <body file> : the first ```bash block after the cookbook line matching <ERE>, as
# a script: OWNER/NAME becomes o/n, and each line that is a <...> placeholder alone becomes the
# body file's lines. The body's lines then sit in the recipe's real heredoc, run by bash.
recipe() {
  awk -v re="$1" -v bodyf="$2" '
    !on && $0 ~ re { on = 1; next }
    on && !grab && /^ *```bash$/ { grab = 1; ind = index($0, "`") - 1; next }
    grab && /^ *```$/ { exit }
    grab {
      $0 = substr($0, ind + 1)
      if ($0 ~ /^<[^>]*>$/) { while ((getline l < bodyf) > 0) print l; close(bodyf); next }
      gsub("OWNER/NAME", "o/n"); print
    }' "$COOKBOOK"
}
# A body that would run commands if bash read it: quotes, a substitution, backticks, a `;`, and
# a line EOF (only OCTO_BODY_EOF ends the heredoc).
cat >"$tmp/body" <<BODY
Error: expected 'foo' to equal "bar" (it's flaky; we can't repro)
\$(touch $tmp/ran-subst) and \`touch $tmp/ran-tick\`; touch $tmp/ran-semi
EOF
a backslash \\ a tab${tab}and \$HOME, ## not a heading
BODY
recipe '^- [*][*]Every body goes on stdin[*][*]' "$tmp/body" >"$tmp/create.sh"
same "the cookbook's rule is one -F body=@- call and its quoted heredoc" "1|1|1" \
  "$(grep -c -- '-F body=@-' "$tmp/create.sh")|$(grep -c "<<'OCTO_BODY_EOF'\$" "$tmp/create.sh")|$(grep -cx OCTO_BODY_EOF "$tmp/create.sh")"
fresh
out="$(PATH="$stub:$PATH" bounded 20 bash "$tmp/create.sh" </dev/null 2>"$tmp/stderr")"; rc=$?
same "the documented create runs and prints <number> <url>" \
  "0|1 https://github.com/o/n/issues/1" "$rc|$out"
same "the title goes raw, the labels as an array, the body from stdin" \
  "ISSUE 1 raw:title=<title> raw:labels[]=feature typed:body=@-" "$(cat "$FX/writes")"
cmp -s "$tmp/body" "$FX/stdin.1" && ok "the body arrives byte for byte" ||
  no "the body arrives byte for byte"
ls "$tmp"/ran-* >/dev/null 2>&1 && no "nothing in the body ran" || ok "nothing in the body ran"

fresh; issue 42 open; rm -f "$tmp"/ran-*
recipe '^Comment, or replace the whole body' "$tmp/body" >"$tmp/comment.sh"
out="$(PATH="$stub:$PATH" bounded 20 bash "$tmp/comment.sh" </dev/null 2>"$tmp/stderr")"; rc=$?
same "the documented comment and PATCH run, each with its body on stdin" \
  "0|COMMENT 42 typed:body=@-${nl}PATCH 42 typed:body=@-" "$rc|$(cat "$FX/writes")"
cmp -s "$tmp/body" "$FX/stdin.1" && cmp -s "$tmp/body" "$FX/stdin.2" &&
  ok "both bodies arrive byte for byte" || no "both bodies arrive byte for byte"
ls "$tmp"/ran-* >/dev/null 2>&1 && no "nothing in either body ran" || ok "nothing in either body ran"

fresh; rm -f "$tmp"/ran-*
recipe '^## Open a pull request' "$tmp/body" >"$tmp/pr.sh"
same "the cookbook's PR create is one -F body=@- call and its quoted heredoc" "1|1|1" \
  "$(grep -c -- '-F body=@-' "$tmp/pr.sh")|$(grep -c "<<'OCTO_BODY_EOF'\$" "$tmp/pr.sh")|$(grep -cx OCTO_BODY_EOF "$tmp/pr.sh")"
out="$(PATH="$stub:$PATH" bounded 20 bash "$tmp/pr.sh" </dev/null 2>"$tmp/stderr")"; rc=$?
same "the documented PR create runs and prints <number> <url>" \
  "0|1 https://github.com/o/n/pull/1" "$rc|$out"
same "title, head, and base go raw, the body from stdin" \
  "PULL 1 raw:title=feat: add OAuth login raw:head=42-add-oauth-login raw:base=main typed:body=@-" \
  "$(cat "$FX/writes")"
{ printf 'Closes #42\n\n## Summary\n'; cat "$tmp/body"; } >"$tmp/pr-body"
cmp -s "$tmp/pr-body" "$FX/stdin.1" && ok "the PR body arrives byte for byte" ||
  no "the PR body arrives byte for byte"
ls "$tmp"/ran-* >/dev/null 2>&1 && no "nothing in the PR body ran" || ok "nothing in the PR body ran"

fresh; pr 43 open 42-add-oauth-login "Closes #42"
recipe '^It prints `<number> <url>`. Add `-F draft=true`' "$tmp/body" >"$tmp/reviewers.sh"
out="$(PATH="$stub:$PATH" bounded 20 bash "$tmp/reviewers.sh" </dev/null 2>"$tmp/stderr")"; rc=$?
same "the documented reviewer request sends each login raw, as an array" \
  "0|REVIEWERS 43 raw:reviewers[]=alice raw:reviewers[]=bob" "$rc|$(cat "$FX/writes")"

fresh; pr 43 open 42-add-oauth-login "Closes #42"; rm -f "$tmp"/ran-*
recipe '^## Post a review' "$tmp/body" >"$tmp/review.sh"
out="$(PATH="$stub:$PATH" bounded 20 bash "$tmp/review.sh" </dev/null 2>"$tmp/stderr")"; rc=$?
same "the documented review posts as a COMMENT, its body from stdin, and prints its URL" \
  "0|https://github.com/o/n/pull/43#pullrequestreview-1|REVIEW 43 raw:event=COMMENT typed:body=@-" \
  "$rc|$out|$(cat "$FX/writes")"
cmp -s "$tmp/body" "$FX/stdin.1" && ok "the review body arrives byte for byte" ||
  no "the review body arrives byte for byte"
ls "$tmp"/ran-* >/dev/null 2>&1 && no "nothing in the review body ran" || ok "nothing in the review body ran"

echo "• the cookbook's pull request reads"
fresh; pr 43 open 42-add-oauth-login "Closes #42"; pr 44 closed other
echo '[{"status": "modified", "filename": "src/a.sh"}, {"status": "added", "filename": "b c.md"},
  {"status": "renamed", "filename": "d", "previous_filename": "e"}]' >"$FX/prlists/43.files.json"
printf 'diff --git a/src/a.sh b/src/a.sh\n' >"$FX/prlists/43.diff"
recipe '^`GET repos/OWNER/NAME/pulls/N` names' /dev/null >"$tmp/read.sh"
out="$(PATH="$stub:$PATH" bounded 20 bash "$tmp/read.sh" </dev/null 2>"$tmp/stderr")"; rc=$?
same "the documented reads run" "0|" "$rc|$(cat "$tmp/stderr")"
same "one PR's fields, by their REST names" \
  '{"number":43,"title":"PR 43","state":"open","merged":false,"draft":false,"author":"dev","head":"42-add-oauth-login","head_sha":"sha43","base":"main","url":"https://github.com/o/n/pull/43"}' \
  "$(PATH="$stub:$PATH" bash -c "$(sed -n '/^gh api repos\/o\/n\/pulls\/43 --jq/,/}'"'"'$/p' "$tmp/read.sh")" | jq -c .)"
same "the PRs on a branch, in any state" "43 open" "$(grep -x '43 open' <<<"$out")"
same "every changed file, every page" "modified${tab}src/a.sh${nl}added${tab}b c.md${nl}renamed${tab}d" \
  "$(grep -E "^(modified|added|renamed)${tab}" <<<"$out")"
same "the diff, by its Accept header" "diff --git a/src/a.sh b/src/a.sh" "$(tail -n 1 <<<"$out")"

fresh; pr 43 open b
echo '[{"user": {"login": "z"}, "state": "COMMENTED", "submitted_at": "t1", "html_url": "r1", "body": "**Verdict:** approve"},
  {"user": {"login": "a"}, "state": "APPROVED", "submitted_at": "t2", "html_url": "r2", "body": ""},
  {"user": {"login": "z"}, "state": "COMMENTED", "submitted_at": "t3", "html_url": "r3", "body": "two\nlines"}]' \
  >"$FX/prlists/43.reviews.json"
echo '[{"user": {"login": "z"}, "path": "a.sh", "line": null, "original_line": 4, "html_url": "c1", "body": "here"}]' \
  >"$FX/prlists/43.comments.json"
echo '[{"user": {"login": "h"}, "author_association": "OWNER", "created_at": "t4", "html_url": "i1", "body": "hi"}]' \
  >"$FX/comments/43.json"
recipe '^Reviews and comments, oldest first' /dev/null >"$tmp/reviews.sh"
out="$(PATH="$stub:$PATH" bounded 20 bash "$tmp/reviews.sh" </dev/null 2>"$tmp/stderr")"; rc=$?
same "the documented review and comment reads run" "" "$(cat "$tmp/stderr")"
same "the documented review and comment reads: every page, each body after its header" \
  "0|--- z COMMENTED t1 r1${nl}**Verdict:** approve${nl}--- a APPROVED t2 r2${nl}${nl}--- z COMMENTED t3 r3${nl}two${nl}lines${nl}--- z a.sh:4 c1${nl}here${nl}--- h (OWNER) t4 i1${nl}hi" \
  "$rc|$out"

echo "• the cookbook's label table is octo-labels.sh's"
# label_table : "<name>|<colour>|<description>" per row of the cookbook's label table.
label_table() {
  sed -nE 's/^\| `([^`]+)` \| `([0-9A-Fa-f]{6})` \| (.*)\|$/\1|\2|\3/p' "$COOKBOOK" |
    sed -E 's/ +$//'
}
table="$(label_table)"
spec_names="$(sed -n '/^spec() {/,/^}/p' "$SCRIPTS_DIR/octo-labels.sh" |
  sed -nE 's/^ +([a-z0-9| -]+)\) +echo.*/\1/p' | tr '|' '\n' | tr -d ' ' | sort)"
same "the table lists exactly the labels spec() defines" "$spec_names" \
  "$(cut -d'|' -f1 <<<"$table" | sort)"
fresh
# shellcheck disable=SC2046 # one argument per label name; none has a space
run octo-labels.sh --repo o/n $(cut -d'|' -f1 <<<"$table")
same "octo-labels.sh creates each with the table's colour and description" \
  "$(sed 's/^\([^|]*\)|\([^|]*\)|\(.*\)$/LABEL raw:name=\1 raw:color=\2 raw:description=\3/' <<<"$table")" \
  "$writes"
# Every raw label create in the docs (continuation lines joined) uses the table's values too.
docs_creates="$(cat "$COOKBOOK" "$SCRIPTS_DIR/../skills/research/SKILL.md" |
  awk '/\\$/ { sub(/\\$/, ""); buf = buf $0; next } { print buf $0; buf = "" }' |
  sed -nE "s/.*labels\"? -f name=([^ ]+) -f color=([0-9A-Fa-f]{6}) +-f description='([^']*)'.*/\1|\2|\3/p")"
[ "$(wc -l <<<"$docs_creates")" -ge 4 ] && ok "the docs' raw label creates were found" ||
  no "the docs' raw label creates were found"
left=""
while IFS= read -r c; do
  grep -Fxq -- "$c" <<<"$table" || left="$left  $c"$'\n'
done <<<"$docs_creates"
if [ -z "$left" ]; then ok "each raw create in the docs matches the table"; else
  no "each raw create in the docs matches the table; differs:"; printf '%s' "$left"; fi

echo "• REST only"
same "no helper call in this suite was rejected" "" "$(cat "$ALL_REJECTED" 2>/dev/null)"
same "every helper call was gh api repos/o/n/..." "" \
  "$(grep -Ev '^api (-X [A-Z]+ |-H Accept: [^ ]+ )?repos/o/n/' "$ALL_LOG")"
[ "$(wc -l <"$ALL_LOG")" -gt 20 ] && ok "the suite made helper calls" || no "the suite made helper calls"

echo
echo "rest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
