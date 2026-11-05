#!/usr/bin/env bash
# cloud.sh — offline tests for what a Claude Code cloud session can't reach: Projects v2 and the
# token's scopes.
#
# Usage:
#   bash scripts/test/cloud.sh
#
# A cloud session's proxy refuses GraphQL with `GitHub GraphQL is not available from Claude Code
# sessions`, and Projects v2 has no REST API, so the board steps must skip with one warning there,
# never fail. A stub `gh` first on PATH answers `gh project` and `gh api graphql` with that 403
# ($GH_PROJECTS=proxy), with another error ($GH_PROJECTS=denied: a scope error, a non-proxy 403),
# or as a small board does ($GH_PROJECTS=ok, the --jq filter run with jq), and with
# $GH_PROXY_AT=<subcommand> refuses only that one `gh project` call. It serves the repo and the
# user over REST. Covers: octo-project-status.sh (exit 3 and one `skipped: projects unavailable
# here` line on the proxy's 403, at its first call or a later one; other failures keep exit 1
# and gh's message; a board that answers still gets its Status set); octo-setup.sh
# (`projects_capable: false` with the `Projects unavailable here` note, or gh's message for other
# failures); octo-doctor.sh (the project checks skipped, exit 0, on the proxy's 403; exit 1 on
# another failure); and octo-bench.sh's preflight, where an empty X-OAuth-Scopes header (the
# proxy injects the credential) is unknown scopes, not a missing repo scope.
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

command -v jq >/dev/null || { echo "cloud: jq is required for the stub gh" >&2; exit 1; }
# No `set -e`: bail out explicitly, or an empty $tmp would point the stub at the real checkout.
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "cloud: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

stub="$tmp/bin"
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
proxy_403() {
  echo 'gh: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). (HTTP 403)' >&2
  exit 1
}
jqf="."
for ((i = 1; i <= $#; i++)); do
  [ "${!i}" != --jq ] || { j=$((i + 1)); jqf="${!j}"; }
done
case "$1 $2" in
  "--version "*) echo "gh version 0.0.0 (stub)" ;;
  "api user") echo octo-cloud ;;
  "api -i")
    # The bench preflight's `gh api -i user`; $GH_SCOPES unset means no header at all.
    printf 'HTTP/2.0 200 OK\r\n'
    [ -z "${GH_SCOPES+x}" ] || printf 'X-Oauth-Scopes: %s\r\n' "$GH_SCOPES"
    printf '\r\n{"login":"stub"}\n' ;;
  "api repos/o/n") jq -nr '{full_name: "o/n", default_branch: "main"}' | jq -r "$jqf" ;;
  "api repos/"*) echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "project "*)
    [ "${GH_PROXY_AT:-}" != "$2" ] || proxy_403
    case "${GH_PROJECTS:-proxy}" in
      proxy) proxy_403 ;;
      denied)
        echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2
        echo "your authentication token is missing required scopes [read:project]" >&2
        exit 1 ;;
    esac
    case "$2" in
      list) json='{"projects":[{"number":7,"title":"Board","url":"https://github.com/users/o/projects/7"}]}' ;;
      view) json='{"id":"PVT_7","title":"Board"}' ;;
      field-list)
        json='{"fields":[{"id":"F_TITLE","name":"Title"},{"id":"F_STATUS","name":"Status",
          "options":[{"id":"O_TODO","name":"Todo"},{"id":"O_PROG","name":"In Progress"}]}]}' ;;
      item-add) json='{"id":"ITEM_1"}' ;;
      item-edit) [ -z "${GH_EDIT_FAIL:-}" ] || { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
        json='{}' ;;
      *) echo "stub gh: unexpected: $*" >&2; exit 9 ;;
    esac
    printf '%s\n' "$json" | jq -r "$jqf" ;;
  "api graphql") proxy_403 ;;
  *) proxy_403 ;;
esac
STUB
chmod +x "$stub/gh"
export GH_LOG="$tmp/gh.log"

# run <script> <args...> : run a helper against the stub; sets out, err, and rc.
run() {
  local s="$1"; shift
  rm -f "$GH_LOG"
  out="$(PATH="$stub:$PATH" bounded 20 bash "$SCRIPTS_DIR/$s" "$@" 2>"$tmp/err")"; rc=$?
  err="$(cat "$tmp/err")"
}

SKIP_LINE='skipped: projects unavailable here (Projects v2 needs GraphQL, which this session refuses)'
PS_ARGS=(--owner o --project 7 --url https://github.com/o/n/issues/5 --status "in progress")

echo "• octo-project-status.sh"
GH_PROJECTS=proxy run octo-project-status.sh "${PS_ARGS[@]}"
same "the proxy's 403: exit 3, one skipped line on stdout, nothing on stderr" \
  "3|$SKIP_LINE|" "$rc|$out|$err"
same "the proxy's 403: it stops at the first board call" "1" "$(grep -c '^gh project' "$GH_LOG")"
GH_PROJECTS=ok GH_PROXY_AT=item-add run octo-project-status.sh "${PS_ARGS[@]}"
same "the proxy's 403 at a later call (item-add): still exit 3 and the skipped line" \
  "3|$SKIP_LINE" "$rc|$out"
GH_PROJECTS=ok GH_PROXY_AT=item-edit run octo-project-status.sh "${PS_ARGS[@]}"
same "the proxy's 403 at the last call (item-edit): still exit 3 and the skipped line" \
  "3|$SKIP_LINE" "$rc|$out"
GH_PROJECTS=denied run octo-project-status.sh "${PS_ARGS[@]}"
same "another 403 (a missing scope) is no skip: exit 1, nothing on stdout" "1|" "$rc|$out"
if printf '%s\n' "$err" | grep -Fq 'Resource not accessible by personal access token' \
   && printf '%s\n' "$err" | grep -Fq 'Cannot access project #7 (owner o)'; then
  ok "another 403: gh's message and the access hint on stderr"
else no "another 403: gh's message and the access hint on stderr (got: $err)"; fi
GH_PROJECTS=ok GH_EDIT_FAIL=1 run octo-project-status.sh "${PS_ARGS[@]}"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && [ -z "$out" ] \
   && printf '%s\n' "$err" | grep -Fq 'Server Error (HTTP 500)'; then
  ok "a failed item-edit is no skip: non-zero, not 3, gh's message on stderr (exit $rc)"
else no "a failed item-edit is no skip (got $rc, out: $out, err: $err)"; fi
GH_PROJECTS=ok run octo-project-status.sh "${PS_ARGS[@]}"
same "a board that answers: exit 0, the Status set (option matched case-insensitively)" \
  '0|Set Status="in progress" for https://github.com/o/n/issues/5 on project #7' "$rc|$out"
same "a board that answers: item-edit gets the item, project, field, and option ids" \
  "gh project item-edit --id ITEM_1 --project-id PVT_7 --field-id F_STATUS --single-select-option-id O_PROG" \
  "$(grep '^gh project item-edit' "$GH_LOG")"

echo "• octo-setup.sh"
GH_PROJECTS=proxy run octo-setup.sh --repo o/n
same "the proxy's 403: exit 0, projects_capable false, no boards" "0|false|[]" \
  "$rc|$(printf '%s' "$out" | jq -r .projects_capable)|$(printf '%s' "$out" | jq -c .boards)"
same "the proxy's 403: the note says projects are unavailable here, not a scope fix" \
  "Projects unavailable here: Projects v2 has no REST API and this session refuses GraphQL (a Claude Code cloud session). The board is skipped." \
  "$(printf '%s' "$out" | jq -r .note)"
GH_PROJECTS=denied run octo-setup.sh --repo o/n
same "another failure: projects_capable false, the note is gh's message as before" \
  "false|gh: Resource not accessible by personal access token (HTTP 403) your authentication token is missing required scopes [read:project]" \
  "$(printf '%s' "$out" | jq -r '"\(.projects_capable)|\(.note)"')"
GH_PROJECTS=ok run octo-setup.sh --repo o/n
same "a board that answers: projects_capable true, its boards listed, no note" "0|true|7|" \
  "$rc|$(printf '%s' "$out" | jq -r '"\(.projects_capable)|\(.boards[0].number)|\(.note)"')"

echo "• octo-doctor.sh"
GH_PROJECTS=proxy run octo-doctor.sh --repo o/n --project 7
if [ "$rc" -eq 0 ] && [ -z "$err" ] \
   && printf '%s\n' "$out" | grep -Fxq '• Projects unavailable here (Projects v2 needs GraphQL, which this session refuses); skipped project checks.' \
   && [ "$(printf '%s\n' "$out" | tail -n 1)" = "Doctor checks passed." ]; then
  ok "the proxy's 403: exit 0, the project checks skipped with one line, the checks pass"
else no "the proxy's 403: exit 0 and the skip line (got $rc, out: $out, err: $err)"; fi
GH_PROJECTS=denied run octo-doctor.sh --repo o/n --project 7
if [ "$rc" -eq 1 ] && printf '%s\n' "$err" | grep -Fq '✗ Cannot access project #7 (owner: o).'; then
  ok "another failure: exit 1, cannot access the project (exit $rc)"
else no "another failure: exit 1 (got $rc, err: $err)"; fi
GH_PROJECTS=ok run octo-doctor.sh --repo o/n --project 7
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Fxq '    - In Progress'; then
  ok "a board that answers: exit 0, its Status options listed"
else no "a board that answers: exit 0 and the options (got $rc, out: $out)"; fi

echo "• octo-bench.sh preflight (the X-OAuth-Scopes header)"
# cleanup reads each of the run's repo names; the stub answers 404, so it ends with "no repos".
bench_cleanup() { run octo-bench.sh cleanup --run-id c1 --live; }
UNKNOWN="octo-bench: cannot read the token's scopes (not a classic token, no scopes, or proxy-injected?); assuming it can create repos"
for v in "" " " "  "; do
  GH_SCOPES="$v" bench_cleanup
  same "an empty header ('$v'), as in a cloud session: unknown scopes, a warning, and cleanup runs" \
    "0|$UNKNOWN|no repos for run c1 under stub" "$rc|$err|$out"
done
(unset GH_SCOPES; bench_cleanup; echo "$rc|$err|$out" >"$tmp/noheader")
same "no header at all: unknown scopes too" "0|$UNKNOWN|no repos for run c1 under stub" \
  "$(cat "$tmp/noheader")"
GH_SCOPES="read:org, gist" bench_cleanup
same "a header without repo still fails: the repo scope is missing" \
  "1|octo-bench: the gh token lacks the repo scope; run \`gh auth refresh -s repo\`" "$rc|$err"
GH_SCOPES="repo, delete_repo" bench_cleanup
same "a header with repo and delete_repo: no warning" "0|" "$rc|$err"

echo
echo "cloud: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
