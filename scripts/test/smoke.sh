#!/usr/bin/env bash
# smoke.sh — CI-safe smoke checks for the octo-*.sh helper scripts.
#
# Verifies each helper's parse surface WITHOUT any network / gh / auth, so it
# runs anywhere (CI, a fresh clone, offline):
#   - bash -n <script>     : the script parses (no syntax errors)
#   - <script> --help      : exits 0 and prints usage
#   - <script> --bogus     : exits 2 (unknown-argument handling)
#   - --help output        : only the header usage block (no later comments / directives)
#
#   - <script> <flag>      : a value flag given last, with no value, exits 2 (never hangs)
#   - octo-exclude.sh      : run for real against a throwaway local `git init` repo
#   - octo-worktree.sh     : add / detach / list / remove run for real in a throwaway local repo
#   - octo-merge-state.sh  : the UNKNOWN re-query loop and gh-error exit, against a stub `gh`
#   - octo-approval-match.sh : pattern normalization, malformed patterns, matching (renames
#                            included), and the incomplete-file-list hold, against a stub `gh`
#   - octo-genesis-check.sh : a valid proposal, a missing section or front-matter key, an
#                            ungrounded proposal (and one with URLs or a misplaced marker), bad
#                            arguments, and --preflight's empty-dir and repo-name checks
#   - octo-bench.sh        : the --live gate and --dry-run make no gh / claude call; preflight,
#                            check's metrics, run's cost cap, and cleanup, against a stub `gh`
#                            and `claude`
#
# It deliberately never invokes a helper in a way that reaches the real gh / the network.
# Exits 0 when every check passes, 1 when any check fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ✓ $1"; }
no() { fail=$((fail + 1)); echo "  ✗ $1"; }

# expect <wanted-exit> <label> <command...>
expect() {
  wanted="$1"; label="$2"; shift 2
  "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$wanted" ]; then ok "$label (exit $rc)"; else no "$label (wanted $wanted, got $rc)"; fi
}

# help_is_header <script> : --help prints exactly the leading comment block (after the shebang, up
# to the first non-comment line) and that block has a Usage section — no later comments leak in.
help_is_header() {
  header="$(awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$1")"
  [ "$(bash "$1" --help 2>/dev/null)" = "$header" ] && printf '%s\n' "$header" | grep -Fq 'Usage:'
}

shopt -s nullglob
scripts=("$SCRIPTS_DIR"/octo-*.sh)
if [ "${#scripts[@]}" -eq 0 ]; then
  echo "smoke: no octo-*.sh scripts found in $SCRIPTS_DIR" >&2
  exit 1
fi

for s in "${scripts[@]}"; do
  echo "• $(basename "$s")"
  expect 0 "syntax (bash -n)"    bash -n "$s"
  expect 0 "--help exits 0"      bash "$s" --help
  expect 2 "unknown arg exits 2" bash "$s" --octo-smoke-bogus-arg
  expect 0 "--help shows the usage block only" help_is_header "$s"
done

# bounded <seconds> <command...> : SIGALRM-kill a hung command (macOS has no `timeout`).
bounded() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }

echo "• missing flag value (arg parsing)"
# A trailing flag with no value must exit 2 — not spin on a failed `shift 2` (no `set -e`) nor
# die with a silent exit 1 (`set -e`). Each fails during parsing, before any gh / git call.
expect 2 "octo-setup.sh --repo exits 2"           bounded 10 bash "$SCRIPTS_DIR/octo-setup.sh" --repo
expect 2 "octo-doctor.sh --repo exits 2"          bounded 10 bash "$SCRIPTS_DIR/octo-doctor.sh" --repo
expect 2 "octo-subissue.sh --child exits 2" \
  bounded 10 bash "$SCRIPTS_DIR/octo-subissue.sh" --repo o/n --parent 1 --child
expect 2 "octo-project-status.sh --status exits 2" \
  bounded 10 bash "$SCRIPTS_DIR/octo-project-status.sh" --owner o --project 1 --status
expect 2 "octo-worktree.sh add --base exits 2" \
  bounded 10 bash "$SCRIPTS_DIR/octo-worktree.sh" add --branch b --base
expect 2 "octo-worktree.sh detach --ref exits 2" \
  bounded 10 bash "$SCRIPTS_DIR/octo-worktree.sh" detach --name n --ref
expect 2 "octo-merge-state.sh --pr exits 2" \
  bounded 10 bash "$SCRIPTS_DIR/octo-merge-state.sh" --repo o/n --pr
expect 2 "octo-merge-state.sh non-numeric --tries exits 2" \
  bounded 10 bash "$SCRIPTS_DIR/octo-merge-state.sh" --repo o/n --pr 1 --tries x
expect 2 "octo-approval-match.sh --pr exits 2" \
  bounded 10 bash "$SCRIPTS_DIR/octo-approval-match.sh" --pattern a --repo o/n --pr
expect 2 "octo-approval-match.sh with no --pattern exits 2" \
  bounded 10 bash "$SCRIPTS_DIR/octo-approval-match.sh" --repo o/n --pr 1
expect 2 "octo-bench.sh setup --run-id exits 2" \
  bounded 10 bash "$SCRIPTS_DIR/octo-bench.sh" setup vsort-numeric --dry-run --run-id

echo "• octo-exclude.sh (offline, temp repo)"
# No `set -e`: bail out explicitly, or an empty $tmp would point git/cd at the real checkout.
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "smoke: mktemp failed" >&2; exit 1; }
wtmp="$(mktemp -d)" && [ -n "$wtmp" ] || { echo "smoke: mktemp failed" >&2; rm -rf "$tmp"; exit 1; }
trap 'rm -rf "$tmp" "$wtmp"' EXIT
git -C "$tmp" init -q || { echo "smoke: git init failed in $tmp" >&2; exit 1; }
mkdir -p "$tmp/.claude" "$tmp/.octoperator/worktrees/1-x"
touch "$tmp/.claude/octoperator.local.md" "$tmp/.octoperator/worktrees/1-x/f"
printf '*.swp' >"$tmp/.git/info/exclude"   # no trailing newline: appends must not join this line
exclude_in_tmp() { (cd "$tmp" && bash "$SCRIPTS_DIR/octo-exclude.sh"); }
expect 0 "first run exits 0"  exclude_in_tmp
expect 0 "second run exits 0" exclude_in_tmp
expect 0 "octoperator files hidden from status" test -z "$(git -C "$tmp" status --porcelain)"
expect 0 "idempotent (one entry each)" test "$(grep -Fxc -e /.claude/octoperator.local.md -e /.octoperator/ "$tmp/.git/info/exclude")" -eq 2
expect 0 "existing entry preserved" grep -Fqx '*.swp' "$tmp/.git/info/exclude"

echo "• octo-worktree.sh (offline, temp repo)"
repo="$wtmp/repo"
wt="$wtmp/wt-1"
# Pin identity / signing / hooks so a developer's global git config cannot break the fixture.
if ! { git init -q "$repo" \
       && git -C "$repo" -c user.name=smoke -c user.email=smoke@example.invalid \
            -c commit.gpgsign=false commit -q --no-verify --allow-empty -m init; }; then
  echo "smoke: could not create a commit in $repo" >&2; exit 1
fi
worktree() { (cd "$repo" && bash "$SCRIPTS_DIR/octo-worktree.sh" "$@"); }
out="$(worktree add --branch 1-smoke --path "$wt" --base HEAD 2>/dev/null)"
add_rc=$?
expect 0 "add exits 0" test "$add_rc" -eq 0
expect 0 "add creates the tree" test -d "$wt"
# The contract is "prints the path": git's "HEAD is now at …" must not leak onto stdout.
expect 0 "add prints only the path on stdout" test "$out" = "$wt"
expect 0 "add creates the branch" git -C "$repo" show-ref --verify --quiet refs/heads/1-smoke
expect 1 "add again (branch taken) exits 1" worktree add --branch 1-smoke --path "$wtmp/wt-2" --base HEAD
expect 0 "list shows the branch" \
  test -n "$(worktree list | grep -Fx 'branch refs/heads/1-smoke')"
touch "$wt/untracked"
expect 1 "remove refuses a dirty tree" worktree remove --path "$wt"
expect 0 "dirty tree kept after refusal" test -d "$wt"
expect 0 "remove --force exits 0" worktree remove --path "$wt" --force
expect 0 "forced remove deletes the tree" test ! -e "$wt"
worktree add --branch 2-smoke --path "$wt" --base HEAD >/dev/null 2>&1
expect 0 "remove (clean) exits 0" worktree remove --path "$wt"
expect 0 "list no longer shows it" \
  test -z "$(worktree list | grep -Fx 'branch refs/heads/2-smoke')"
head_sha="$(git -C "$repo" rev-parse HEAD)"
dout="$(worktree detach --name review-1 --ref "$head_sha" 2>/dev/null)"
expect 0 "detach exits 0" test $? -eq 0
expect 0 "detach prints only the path, under .octoperator/worktrees" \
  test "${dout%-*}" = "$(cd "$repo" && pwd -P)/.octoperator/worktrees/review-1"
expect 0 "detach checks out the commit, detached" \
  test "$(git -C "$dout" rev-parse HEAD)" = "$head_sha" -a -z "$(git -C "$dout" branch --show-current)"
expect 0 "detach --ref of an unknown commit fails" \
  test "$(worktree detach --name review-2 --ref 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; echo $?)" -ne 0
expect 0 "remove --force removes a detached tree" worktree remove --path "$dout" --force

echo "• octo-merge-state.sh (offline, stub gh)"
# A stub `gh` first on PATH: it counts its calls in a file beside itself, prints UNKNOWN for the
# first $STUB_UNKNOWN calls and CLEAN after, or exits $STUB_GH_RC when that is non-zero.
stub="$wtmp/stub-bin"
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
calls="$(dirname "$0")/calls"
n=$(( $(cat "$calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$calls"
[ "${STUB_GH_RC:-0}" -eq 0 ] || exit "$STUB_GH_RC"
if [ "$n" -le "${STUB_UNKNOWN:-0}" ]; then echo UNKNOWN; else echo CLEAN; fi
STUB
chmod +x "$stub/gh"
# merge_state <unknown-calls> <gh-exit> : run the helper against the stub; sets ms_out / ms_rc /
# ms_calls.
merge_state() {
  rm -f "$stub/calls"
  ms_out="$(STUB_UNKNOWN="$1" STUB_GH_RC="$2" PATH="$stub:$PATH" \
    bounded 10 bash "$SCRIPTS_DIR/octo-merge-state.sh" --repo o/n --pr 1 --interval 0 2>/dev/null)"
  ms_rc=$?
  ms_calls="$(cat "$stub/calls" 2>/dev/null || echo 0)"
}
merge_state 0 0
expect 0 "CLEAN at once: prints CLEAN after 1 call" \
  test "$ms_rc/$ms_out/$ms_calls" = "0/CLEAN/1"
merge_state 2 0
expect 0 "UNKNOWN x2 then CLEAN: prints CLEAN after 3 calls" \
  test "$ms_rc/$ms_out/$ms_calls" = "0/CLEAN/3"
merge_state 99 0
expect 0 "always UNKNOWN: gives up after --tries (3), prints UNKNOWN" \
  test "$ms_rc/$ms_out/$ms_calls" = "0/UNKNOWN/3"
merge_state 0 4
expect 0 "gh exit 4 (auth): exits 1, prints nothing" test "$ms_rc/$ms_out" = "1/"
merge_state 0 2
expect 0 "gh exit 2: exits 1, not the bad-arguments 2" test "$ms_rc/$ms_out" = "1/"

echo "• octo-approval-match.sh (offline, stub gh)"
# A stub `gh` first on PATH logs each call to $STUB_LOG. `api` prints the file list in $STUB_FILES
# as the helper's jq filter would (one line per file: its path, a tab, then a rename's old path);
# it does not run the filter itself. `pr view` prints $STUB_COUNT, or the list's line count when
# that is unset. Both exit $STUB_GH_RC when that is non-zero.
astub="$wtmp/approval-bin"
mkdir -p "$astub"
cat >"$astub/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $1" >>"$STUB_LOG"
[ "${STUB_GH_RC:-0}" -eq 0 ] || exit "$STUB_GH_RC"
case "$1" in
  api) cat "$STUB_FILES" ;;
  pr) echo "${STUB_COUNT:-$(grep -c '' "$STUB_FILES")}" ;;
esac
STUB
chmod +x "$astub/gh"
STUB_LOG="$wtmp/approval-log"
STUB_FILES="$wtmp/approval-files"
export STUB_LOG STUB_FILES
# norm <pattern> : the helper's normalized form of one pattern.
norm() { bounded 10 bash "$SCRIPTS_DIR/octo-approval-match.sh" --pattern "$1" --normalize; }
for case in '/infra/=infra/**' 'infra/=infra/**' 'infra=**/infra' '*.tf=**/*.tf' \
    '**/*.tf=**/*.tf' '.github/workflows/=.github/workflows/**' './a/b=a/b' '**/**/x=**/x' \
    '/infra=infra' './infra=infra' '/*.tf=*.tf'; do
  expect 0 "normalizes ${case%%=*} to ${case#*=}" test "$(norm "${case%%=*}")" = "${case#*=}"
done
for bad in '' / 'a?' 'a[b]' '{a,b}' '!a' 'a\b' 'a**' '**b/c' 'a//b' '../x'; do
  rm -f "$STUB_LOG"
  expect 2 "malformed '$bad' exits 2" \
    bounded 10 bash "$SCRIPTS_DIR/octo-approval-match.sh" --pattern ok --pattern "$bad" \
      --repo o/n --pr 1
  expect 0 "malformed '$bad' makes no gh call" test ! -e "$STUB_LOG"
done
# approval <pattern...> : run the helper against the stub's $STUB_FILES; sets am_out / am_rc.
approval() {
  local args=() p
  for p in "$@"; do args+=(--pattern "$p"); done
  am_out="$(PATH="$astub:$PATH" bounded 10 bash "$SCRIPTS_DIR/octo-approval-match.sh" \
    "${args[@]}" --repo o/n --pr 1 2>/dev/null)"
  am_rc=$?
}
tab="$(printf '\t')"
printf '%s\t\n' README.md main.tf main.tfvars modules/net/vpc.tf infra/main.tf infra-old/x \
  infrastructure/x deploy/infra/run.sh .github/workflows/ci.yml xgithub/workflows/ci.yml \
  >"$STUB_FILES"
# matches <pattern> <expected paths, space-separated> : the helper exits 1 and prints exactly
# these paths, each with the pattern.
matches() {
  local want="" p
  for p in $2; do want="$want$p$tab$1"$'\n'; done
  approval "$1"
  expect 0 "'$1' matches only: $2" test "$am_rc" -eq 1 -a "$am_out"$'\n' = "$want"
}
matches '/infra/' 'infra/main.tf'
matches 'infra/' 'infra/main.tf'
matches 'infra' 'infra/main.tf deploy/infra/run.sh'
matches '*.tf' 'main.tf modules/net/vpc.tf infra/main.tf'
matches '**/*.tf' 'main.tf modules/net/vpc.tf infra/main.tf'
matches '.github/workflows/' '.github/workflows/ci.yml'
matches 'modules/**/vpc.tf' 'modules/net/vpc.tf'
matches '/infra' 'infra/main.tf'
approval 'docs/**' 'secrets/**' 'Infra'
expect 0 "no match: exits 0, prints nothing" test "$am_rc" -eq 0 -a -z "$am_out"
printf 'docs/ci.yml%s.github/workflows/ci.yml\n' "$tab" >"$STUB_FILES"
approval '.github/workflows/'
expect 0 "rename: the old path alone matches" \
  test "$am_rc" -eq 1 -a "$am_out" = ".github/workflows/ci.yml$tab.github/workflows/"
STUB_COUNT=2 approval 'nothing'
expect 0 "fewer files listed than changedFiles: exits 3" test "$am_rc" -eq 3
# A tab or newline inside a path would split it into pieces the pattern misses. Real gh fails in
# the jq filter; these cases cover the helper's own line checks behind it.
printf '.github/workflows/x\t.yml\t\n' >"$STUB_FILES"
approval '.github/workflows/*.yml'
expect 0 "tab in a changed path: exits 3" test "$am_rc" -eq 3
printf '.github/workflows/x\n.yml\t\n' >"$STUB_FILES"
STUB_COUNT=1 approval '.github/workflows/*.yml'
expect 0 "newline in a changed path: exits 3" test "$am_rc" -eq 3
printf 'a\tb\nc\t\n' >"$STUB_FILES"
STUB_COUNT=1 approval 'nothing'
expect 0 "tab and newline in one path: exits 3" test "$am_rc" -eq 3
STUB_COUNT=3000 approval 'nothing'
expect 0 "3000 changed files (the API limit): exits 3" test "$am_rc" -eq 3
STUB_GH_RC=2 approval 'nothing'
expect 0 "gh exit 2: exits 3, not the malformed-pattern 2" test "$am_rc" -eq 3

echo "• octo-genesis-check.sh (offline, temp dirs)"
GENESIS="$SCRIPTS_DIR/octo-genesis-check.sh"
# genesis_fixture <dir> : write a valid, grounded proposal into <dir>.
genesis_fixture() {
  mkdir -p "$1/docs"
  cat >"$1/GENESIS.md" <<'MD'
---
sentence: |-
  A character-chat app: it remembers you across long conversations.
repo: smoke/chat-pal
visibility: private
---

# Genesis proposal
MD
  cat >"$1/docs/research.md" <<'MD'
# Research: chat-pal

## Problem

Chat companions forget earlier conversations (https://foo.example/blog).

## Prior art

| Name | Kind | URL | License | Strengths | Gaps |
|------|------|-----|---------|-----------|------|
| Foo | service | https://foo.example | proprietary | polish | forgets |
| Bar | OSS | https://github.com/x/bar | MIT | self-hosted | no memory |

## Build

- Long-term memory per user (https://foo.example/blog)

## Skip

- Voice calls — costly, and neither project's users ask for them (https://github.com/x/bar)

## Sources

- https://foo.example/blog — Foo's blog, accessed 2026-11-01
- <https://github.com/x/bar> — accessed 2026-11-01
MD
}
# genesis_check <args...> : run the helper; sets gc_out (stdout) and gc_rc.
genesis_check() { gc_out="$(bounded 10 bash "$GENESIS" "$@" 2>/dev/null)"; gc_rc=$?; }
g="$wtmp/genesis"
genesis_fixture "$g/valid"
genesis_check "$g/valid"
expect 0 "valid proposal: exits 0, prints nothing" test "$gc_rc" -eq 0 -a -z "$gc_out"
genesis_fixture "$g/nosection"
sed 's/^## Skip$/## Avoid/' "$g/valid/docs/research.md" >"$g/nosection/docs/research.md"
genesis_check "$g/nosection"
expect 0 "missing ## Skip: exits 1 with a FAIL line" test "$gc_rc" -eq 1 \
  -a "$gc_out" = "FAIL: docs/research.md: missing section ## Skip"
genesis_fixture "$g/nokey"
grep -v '^visibility:' "$g/valid/GENESIS.md" >"$g/nokey/GENESIS.md"
genesis_check "$g/nokey"
expect 0 "missing visibility key: exits 1 with a FAIL line" test "$gc_rc" -eq 1 \
  -a -n "$(printf '%s\n' "$gc_out" | grep -Fx \
    "FAIL: GENESIS.md: front matter needs visibility: private or public (got '')")"
genesis_fixture "$g/nourl"
sed 's|^- Long-term memory per user .*|- Long-term memory per user|' \
  "$g/valid/docs/research.md" >"$g/nourl/docs/research.md"
genesis_check "$g/nourl"
expect 0 "grounded Build item with no URL: exits 1" test "$gc_rc" -eq 1 \
  -a "$gc_out" = "FAIL: docs/research.md: 1 ## Build item(s) cite no URL"
# Ungrounded: no rows, no sources, and items without URLs all pass.
genesis_fixture "$g/ungrounded"
awk '/^## Problem$/ { print "ungrounded: no web access"; print "" } /^\| (Foo|Bar) / { next }
     /^## Sources$/ { print; exit } { gsub(/ \(https:[^)]*\)/, ""); print }' \
  "$g/valid/docs/research.md" >"$g/ungrounded/docs/research.md"
genesis_check "$g/ungrounded"
expect 0 "ungrounded proposal with no sources: exits 0" test "$gc_rc" -eq 0 -a -z "$gc_out"
# The marker on a grounded file: its rows, sources, and URLs are all reported.
genesis_fixture "$g/ungurl"
awk '/^## Problem$/ { print "ungrounded: no web access"; print "" } { print }' \
  "$g/valid/docs/research.md" >"$g/ungurl/docs/research.md"
genesis_check "$g/ungurl"
expect 0 "ungrounded marker with rows, sources, and URLs: exits 1, three FAIL lines" \
  test "$gc_rc" -eq 1 -a "$gc_out" \
    = "FAIL: docs/research.md: ungrounded, but ## Prior art has 2 row(s)"$'\n'"FAIL: \
docs/research.md: ungrounded, but ## Sources has 2 item(s)"$'\n'"FAIL: docs/research.md: \
ungrounded, but 7 line(s) cite an http(s) URL"
genesis_fixture "$g/unglate"
# The ungrounded proposal, its marker moved under ## Problem.
awk '/^ungrounded:/ { next } { print } /^## Problem$/ { print "ungrounded: no web access" }' \
  "$g/ungrounded/docs/research.md" >"$g/unglate/docs/research.md"
genesis_check "$g/unglate"
expect 0 "ungrounded marker under ## Problem: exits 1, names the placement" test "$gc_rc" -eq 1 \
  -a -n "$(printf '%s\n' "$gc_out" | grep -Fx "FAIL: docs/research.md: the line \
'ungrounded: no web access' must come before ## Problem")"
expect 2 "no DIR exits 2"            bounded 10 bash "$GENESIS"
expect 2 "two DIRs exit 2"           bounded 10 bash "$GENESIS" "$g/valid" "$g/nokey"
expect 2 "a missing DIR exits 2"     bounded 10 bash "$GENESIS" "$g/nosuch"
expect 2 "--preflight with no DIR exits 2" bounded 10 bash "$GENESIS" --preflight
mkdir -p "$g/empty-1/.claude"
genesis_check --preflight "$g/empty-1"
expect 0 "--preflight, only .claude/: exits 0, prints the path" \
  test "$gc_rc" -eq 0 -a "$gc_out" = "$(cd "$g/empty-1" && pwd)"
genesis_check --preflight "$g/valid"
# Glob order depends on the locale, so compare sorted.
expect 0 "--preflight, non-empty: exits 1, names each entry" test "$gc_rc" -eq 1 \
  -a "$(printf '%s\n' "$gc_out" | LC_ALL=C sort)" \
    = "FAIL: directory not empty: GENESIS.md"$'\n'"FAIL: directory not empty: docs"
mkdir -p "$g/bad name" && touch "$g/bad name/.hidden"
genesis_check --preflight "$g/bad name"
expect 0 "--preflight, a dotfile and an invalid repo name: exits 1, two FAIL lines" \
  test "$gc_rc" -eq 1 -a "$(printf '%s\n' "$gc_out" | grep -c '^FAIL: ')" -eq 2
# A UTF-8 locale must not let a non-ASCII letter pass as a repo-name letter.
mkdir -p "$g/caf"$'\xc3\xa9'
gc_out="$(LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bounded 10 bash "$GENESIS" --preflight \
  "$g/caf"$'\xc3\xa9' 2>/dev/null)"; gc_rc=$?
expect 0 "--preflight, a non-ASCII letter under a UTF-8 locale: exits 1" test "$gc_rc" -eq 1 \
  -a -n "$(printf '%s\n' "$gc_out" | grep '^FAIL: directory name ')"

echo "• octo-bench.sh (offline, stub gh and claude)"
# Stubs first on PATH log every call to $STUB_LOG. gh answers from the fixture dir $STUB_CASE:
# `repo clone` copies $STUB_CASE/repo, `pr list` / `pr view` print list.json / view.json, and
# `repo list --json name --jq .[].name` applies that filter to repos.json. claude sleeps
# $STUB_CLAUDE_SLEEP seconds first, when set.
bstub="$wtmp/bench-bin"
mkdir -p "$bstub"
cat >"$bstub/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_LOG"
case "$1 $2" in
  "api -i") printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: %s\r\n\r\n{"login":"stub"}\n' \
              "${STUB_SCOPES-repo, delete_repo}" ;;
  "repo clone") mkdir "$4" && cp -R "$STUB_CASE/repo/." "$4/" ;;  # gh repo clone <repo> <dir>
  "pr list") cat "$STUB_CASE/list.json" ;;
  "pr view") cat "$STUB_CASE/view.json" ;;
  "repo list")
    case " $* " in
      *" --json name --jq .[].name "*) ;;
      *) echo "stub gh: bad: $*" >&2; exit 1 ;;
    esac
    python3 -c 'import json, sys
for r in json.load(open(sys.argv[1])): print(r["name"])' "$STUB_CASE/repos.json" ;;
  "repo create"|"repo delete"|"label create") ;;
  "issue create") cat >/dev/null; echo "https://github.com/stub/x/issues/1" ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 1 ;;
esac
STUB
cat >"$bstub/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude $*" >>"$STUB_LOG"
[ -z "${STUB_CLAUDE_SLEEP:-}" ] || exec sleep "$STUB_CLAUDE_SLEEP"
echo '{"total_cost_usd": 3, "num_turns": 5, "modelUsage": {"stub-model": {"costUSD": 3}}}'
STUB
chmod +x "$bstub/gh" "$bstub/claude"
export STUB_LOG="$wtmp/bench.log" BENCH_RESULTS_DIR="$wtmp/results"
BENCH="$SCRIPTS_DIR/octo-bench.sh"
bench() { PATH="$bstub:$PATH" bounded 60 bash "$BENCH" "$@"; }
# no_calls <label> <wanted-exit> <args...> : exits <wanted-exit> without calling gh or claude.
no_calls() {
  label="$1"; wanted="$2"; shift 2
  rm -f "$STUB_LOG"
  bench "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$wanted" ] && [ ! -s "$STUB_LOG" ]; then ok "$label (exit $rc, no gh/claude)"
  else no "$label (wanted exit $wanted and no calls, got $rc: $(cat "$STUB_LOG" 2>/dev/null))"
  fi
}
r=o/octo-bench-vsort-numeric-r1
no_calls "setup without --live exits 2" 2 setup vsort-numeric --run-id r1
no_calls "solve without --live exits 2" 2 solve "$r" 1
no_calls "check without --live exits 2" 2 check vsort-numeric "$r"
no_calls "cleanup without --live exits 2" 2 cleanup --run-id r1
no_calls "run without --live exits 2" 2 run --tasks all --run-id r1
no_calls "setup --dry-run" 0 setup vsort-numeric --run-id r1 --dry-run
no_calls "solve --dry-run" 0 solve "$r" 1 --dry-run
no_calls "check --dry-run" 0 check vsort-numeric "$r" --dry-run
no_calls "cleanup --dry-run" 0 cleanup --run-id r1 --dry-run
no_calls "run --dry-run" 0 run --tasks all --run-id r1 --max-cost-usd 5 --dry-run
no_calls "--live --dry-run is still a dry run" 0 setup vsort-numeric --run-id r1 --live --dry-run
no_calls "solve refuses a non-bench repo" 2 solve zeikar/octoperator 77 --dry-run
no_calls "solve refuses an unknown task's repo" 2 solve o/octo-bench-nosuch-r1 1 --dry-run
dry="$(bench setup vsort-numeric --run-id r1 --owner me --dry-run 2>&1)"
expect 0 "setup --dry-run names the repo and the issue" \
  test -n "$(printf '%s\n' "$dry" | grep -F 'me/octo-bench-vsort-numeric-r1 (private)')" \
    -a -n "$(printf '%s\n' "$dry" | grep -F 'issue: fix: vsort puts')"

# Fixtures: a repo where the reference fix is merged, and the bare seed.
cases="$wtmp/cases"
mkdir -p "$cases/merged/repo" "$cases/held/repo" "$cases/nopr/repo"
seed="$SCRIPTS_DIR/../bench/tasks/vsort-numeric"
cp -R "$seed/seed/." "$cases/merged/repo/" && cp -R "$seed/seed/." "$cases/held/repo/" \
  && cp -R "$seed/seed/." "$cases/nopr/repo/" \
  && (cd "$cases/merged/repo" && git apply "$seed/solution.patch") \
  || { echo "smoke: could not build the octo-bench fixtures" >&2; exit 1; }
echo '[{"number": 7}]' >"$cases/merged/list.json"
cat >"$cases/merged/view.json" <<'JSON'
{"number": 7, "state": "MERGED", "isDraft": false, "mergeStateStatus": "UNKNOWN", "reviews": [
 {"body": "**Intended verdict: request_changes.** Self.\n\n### Major\n- a"},
 {"body": "**Intended verdict: request_changes.**\n\n### Blockers\n- b\n\n### Minor\n- c"},
 {"body": "Looks good.\n\n### Minor\n- a human review, not Octoperator's"},
 {"body": "**Intended verdict: approve.** Round 2.\n\n### Minor\n- d\n\n### Nits\n- e"}]}
JSON
echo '[{"number": 3}]' >"$cases/held/list.json"
cat >"$cases/held/view.json" <<'JSON'
{"number": 3, "state": "OPEN", "isDraft": false, "mergeStateStatus": "BLOCKED", "reviews": [
 {"body": "**Verdict:** request_changes\n**Summary:** x\n\n### Major\n- a"}]}
JSON
echo '[]' >"$cases/nopr/list.json"
mkdir -p "$BENCH_RESULTS_DIR"
cat >"$BENCH_RESULTS_DIR/octo-bench-vsort-numeric-merged.solve.json" <<'JSON'
{"octoperator_sha": "abc123", "exit": 0, "duration_s": 42, "claude": {"total_cost_usd": 1.25,
 "num_turns": 30, "modelUsage": {"haiku": {"costUSD": 0.01}, "opus": {"costUSD": 1.24}}}}
JSON
# check_case <case> : run check on the fixture; sets cline (stdout) and crc.
check_case() {
  cline="$(STUB_CASE="$cases/$1" bench check vsort-numeric "o/octo-bench-vsort-numeric-$1" --live \
    2>/dev/null)"
  crc=$?
}
# fields <json> <key...> : the keys' JSON values, space-separated.
fields() {
  python3 -c 'import json, sys
d = json.loads(sys.argv[1]); print(" ".join(json.dumps(d[k]) for k in sys.argv[2:]))' "$@" 2>&1
}
metrics="pr merged check_passed success fix_rounds minor_only_rounds held_reason"
solved="cost_usd turns duration_s octoperator_sha model"
check_case merged
expect 0 "check, merged PR, 3 Octoperator reviews (1 minor-only), human review ignored" \
  test "$crc $(fields "$cline" $metrics)" = "0 7 true true true 2 1 null"
expect 0 "check takes cost, turns, duration, sha, and model from solve's JSON" \
  test "$(fields "$cline" $solved)" = '1.25 30 42 "abc123" "opus"'
expect 0 "check appends exactly its line to <results>/<run-id>.jsonl" \
  test "$(cat "$BENCH_RESULTS_DIR/merged.jsonl")" = "$cline"
check_case held
expect 0 "check, open PR held by a blocking review, seed fails the check" \
  test "$crc $(fields "$cline" $metrics)" = '0 3 false false false 0 0 "review blocking"'
expect 0 "check without solve's JSON: nulls, and this checkout's sha" \
  test "$(fields "$cline" $solved)" \
    = "null null null \"$(git -C "$SCRIPTS_DIR" rev-parse HEAD)\" null"
check_case nopr
expect 0 "check, no PR" \
  test "$crc $(fields "$cline" $metrics)" = '0 null false false false 0 0 "no PR"'
expect 0 "check records every field, and no others" test "$(python3 -c 'import json, sys
print(" ".join(sorted(json.loads(sys.argv[1]))))' "$cline")" = "$(printf '%s\n' task repo $metrics \
  $solved | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"

# preflight <scopes> : run check against the no-PR fixture with these token scopes; sets
# pf_out (stdout and stderr) and pf_rc.
preflight() {
  pf_out="$(STUB_SCOPES="$1" STUB_CASE="$cases/nopr" bench check vsort-numeric \
    o/octo-bench-vsort-numeric-nopr --live 2>&1)"
  pf_rc=$?
}
preflight "read:org"
expect 0 "preflight: no repo scope exits 1 with a clear message" \
  test "$pf_rc" -eq 1 -a -n "$(printf '%s\n' "$pf_out" | grep -F 'lacks the repo scope')"
preflight "repo"
expect 0 "preflight: no delete_repo only warns" \
  test "$pf_rc" -eq 0 -a -n "$(printf '%s\n' "$pf_out" | grep -F 'lacks delete_repo')"

# The stub claude reports $3 per solve, so with a $2 cap run stops after the first task.
rm -f "$STUB_LOG"
STUB_CASE="$cases/nopr" bench run --tasks retry-docs,vsort-numeric,wordfreq-top --run-id cap \
  --max-cost-usd 2 --live >/dev/null 2>&1
cap_rc=$?
expect 0 "run --max-cost-usd: stops once the total passes the cap (exit 1, 1 task run)" \
  test "$cap_rc $(grep -c '^claude ' "$STUB_LOG") $(wc -l <"$BENCH_RESULTS_DIR/cap.jsonl" \
    | tr -d ' ')" = "1 1 1"
expect 0 "run records solve's cost and model in the result line" \
  test "$(fields "$(cat "$BENCH_RESULTS_DIR/cap.jsonl")" task cost_usd turns model)" \
    = '"retry-docs" 3 5 "stub-model"'

# A solve that times out leaves no cost: with a cap set, run must not start the next task.
rm -f "$STUB_LOG"
slow_err="$(STUB_CLAUDE_SLEEP=10 BENCH_SOLVE_TIMEOUT=1 STUB_CASE="$cases/nopr" bench run \
  --tasks retry-docs,vsort-numeric --run-id slow --max-cost-usd 0.5 --live 2>&1 >/dev/null)"
slow_rc=$?
expect 0 "run --max-cost-usd: a timed-out solve (no cost) stops the run (exit 1, 1 task)" \
  test "$slow_rc $(grep -c '^claude ' "$STUB_LOG")" = "1 1"
expect 0 "run warns that the timed-out task's cost is unknown" \
  test -n "$(printf '%s\n' "$slow_err" | grep -F 'cost of retry-docs unknown (claude exit 1')"
expect 0 "solve records the timeout's exit and a null claude" \
  test "$(fields "$(cat "$BENCH_RESULTS_DIR/octo-bench-retry-docs-slow.solve.json")" claude)" \
    = null
# Without a cap, run goes on, but its total must name the tasks whose cost is unknown.
slow_err="$(STUB_CLAUDE_SLEEP=10 BENCH_SOLVE_TIMEOUT=1 STUB_CASE="$cases/nopr" bench run \
  --tasks retry-docs,vsort-numeric --run-id slow2 --live 2>&1 >/dev/null)"
expect 0 "run without a cap: the total names the tasks whose cost is unknown" \
  test -n "$(printf '%s\n' "$slow_err" \
    | grep -Fx 'run slow2: total cost $0, plus unknown cost for: retry-docs vsort-numeric')"

# Preflight checks for claude before setup creates any repo. A PATH of links to just the
# tools the script needs before then, plus the stub gh, leaves claude out.
nobin="$wtmp/no-claude-bin"
mkdir -p "$nobin" && ln -s "$bstub/gh" "$nobin/gh"
for c in dirname sed tr grep head tail awk cat mkdir rm mktemp python3 perl git; do
  p="$(command -v "$c")" && ln -s "$p" "$nobin/$c"
done
rm -f "$STUB_LOG"
nc_err="$(PATH="$nobin" bounded 60 "$(command -v bash)" "$BENCH" run --tasks vsort-numeric \
  --run-id nc --live 2>&1 >/dev/null)"
nc_rc=$?
expect 0 "run without claude exits 1 in preflight, creating no repo" \
  test "$nc_rc" -eq 1 -a -n "$(printf '%s\n' "$nc_err" | grep -F 'claude is not installed')" \
    -a -z "$(grep -F 'repo create' "$STUB_LOG" 2>/dev/null)"

# cleanup deletes exactly this run's repos: r1, not r1-2 or r10 (whose names start the same).
mkdir -p "$cases/repos"
cat >"$cases/repos/repos.json" <<'JSON'
[{"name": "octo-bench-vsort-numeric-r1"}, {"name": "octo-bench-vsort-numeric-r1-2"},
 {"name": "octo-bench-vsort-numeric-r10"}, {"name": "octo-bench-retry-docs-r1"},
 {"name": "octoperator"}]
JSON
rm -f "$STUB_LOG"
STUB_CASE="$cases/repos" bench cleanup --run-id r1 --live >/dev/null 2>&1
cl_rc=$?
expect 0 "cleanup --run-id r1 deletes only the -r1 repos" \
  test "$cl_rc $(grep '^gh repo delete' "$STUB_LOG" | tr '\n' ' ')" = "0 gh repo delete \
stub/octo-bench-retry-docs-r1 --yes gh repo delete stub/octo-bench-vsort-numeric-r1 --yes "
rm -f "$STUB_LOG"
cl_err="$(STUB_SCOPES=repo STUB_CASE="$cases/repos" bench cleanup --run-id r1 --live 2>&1)"
cl_rc=$?
expect 0 "cleanup without delete_repo deletes nothing, lists the repos, and exits 1" \
  test "$cl_rc" -eq 1 -a -z "$(grep '^gh repo delete' "$STUB_LOG")" \
    -a -n "$(printf '%s\n' "$cl_err" | grep -Fx '  stub/octo-bench-retry-docs-r1')" \
    -a -n "$(printf '%s\n' "$cl_err" | grep -Fx '  stub/octo-bench-vsort-numeric-r1')"

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
