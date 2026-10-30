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

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
