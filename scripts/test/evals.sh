#!/usr/bin/env bash
# evals.sh — offline tests for the scenario-eval templates genesis copies into a new repo
# (skills/genesis/templates/evals/).
#
# Usage:
#   bash scripts/test/evals.sh
#
#   - run.sh   : against fixture evals that pass, fail, are skipped (judge: model), exit 2, time
#                out, or are malformed; the summary line, the exit code, and the evals-metric
#                notice only under GitHub Actions
#   - guard.sh : against throwaway git repos, a PR that adds a must-fail eval passes; one that adds
#                an eval already passing on the base, modifies, deletes, or renames an eval, or
#                adds a file to an existing eval fails; a model-judged eval is not run; an eval
#                the base gained after the PR branched is not read as deleted
#
# Nothing here calls gh or the network. Exits 0 when every check passes, 1 when any fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(cd "$HERE/../../skills/genesis/templates" && pwd)"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ✓ $1"; }
no() { fail=$((fail + 1)); echo "  ✗ $1"; }
# check <label> <command...> : the command exits 0.
check() { label="$1"; shift; if "$@"; then ok "$label"; else no "$label"; fi; }
# has <text> <line> : the text holds the line exactly.
has() { printf '%s\n' "$1" | grep -Fxq -- "$2"; }

# No `set -e`: bail out explicitly, or an empty $tmp would point git and cd at the real checkout.
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "evals: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
# A developer's own git config (identity, signing, hooks, a default branch) must not change the
# fixtures.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# eval_dir <repo> <id> <judge> [check body] : write evals/<id>/ with scenario.md, and check.sh when
# a body is given.
eval_dir() {
  mkdir -p "$1/evals/$2"
  printf -- '---\nid: %s\njudge: %s\nrequirement: R1\n---\n\nThe scenario.\n' "$2" "$3" \
    >"$1/evals/$2/scenario.md"
  [ $# -lt 4 ] || printf '#!/usr/bin/env bash\n%s\n' "$4" >"$1/evals/$2/check.sh"
}

echo "• evals/run.sh (offline, fixture evals)"
r="$tmp/run"
mkdir -p "$r/evals"
cp "$T/evals/run.sh" "$r/evals/run.sh"
echo v1 >"$r/app.txt"
# The pass fixture also proves the check gets the repo as its argument and runs elsewhere.
eval_dir "$r" pass script '[ -f "$1/app.txt" ] && [ "$PWD" != "$1" ]'
eval_dir "$r" fail script 'echo "FAIL: not built"; exit 1'
eval_dir "$r" model model
eval_dir "$r" badexit script 'echo "Usage: check.sh REPO_DIR" >&2; exit 2'
out="$(GITHUB_ACTIONS=false bash "$r/evals/run.sh" 2>&1)"; rc=$?
check "pass, fail, skip, exit 2: exits 1" test "$rc" -eq 1
check "the summary counts script evals only" has "$out" "evals: 1/3 passed (1 skipped)"
check "each eval's verdict, exit 2 as a failure" test \
  -n "$(has "$out" "pass: pass" && has "$out" "fail: fail (exit 1)" \
    && has "$out" "skip: model (judge: model)" && has "$out" "fail: badexit (exit 2)" && echo y)"
check "a failed eval's output is shown" has "$out" "    FAIL: not built"
check "no notice outside GitHub Actions" test -z "$(printf '%s\n' "$out" | grep '^::notice')"
out="$(GITHUB_ACTIONS=true bash "$r/evals/run.sh" 2>&1)"
check "under GitHub Actions: the evals-metric notice" \
  has "$out" "::notice title=evals-metric::passed=1 total=3"
rm -rf "$r/evals/fail" "$r/evals/badexit"
out="$(GITHUB_ACTIONS=false bash "$r/evals/run.sh" "$r" 2>&1)"; rc=$?
check "every script eval passes (one skipped): exits 0" \
  test "$rc" -eq 0 -a -n "$(has "$out" "evals: 1/1 passed (1 skipped)" && echo y)"
# A check that hangs is killed with the processes it started.
eval_dir "$r" hang script 'sleep 30 & echo $! >"$1/../hang.pid"; wait'
out="$(EVALS_CHECK_TIMEOUT=1 GITHUB_ACTIONS=false bash "$r/evals/run.sh" 2>&1)"; rc=$?
check "a hung check: timed out, counted as failed" test "$rc" -eq 1 \
  -a -n "$(has "$out" "fail: hang (timed out after 1s)" && has "$out" \
    "evals: 1/2 passed (1 skipped)" && echo y)"
check "the hung check's child process is killed too" \
  test -n "$(kill -0 "$(cat "$tmp/hang.pid")" 2>/dev/null || echo gone)"
rm -rf "$r/evals/hang"
mkdir -p "$r/evals/nofile"
eval_dir "$r" nojudge '' 'exit 0'
eval_dir "$r" nocheck script
out="$(GITHUB_ACTIONS=false bash "$r/evals/run.sh" 2>&1)"; rc=$?
check "no scenario.md, no judge, or no check.sh: each failed" test "$rc" -eq 1 \
  -a -n "$(has "$out" "fail: nofile (no scenario.md)" && has "$out" \
    "fail: nojudge (judge must be script or model, got '')" && has "$out" \
    "fail: nocheck (no check.sh)" && has "$out" "evals: 1/4 passed (1 skipped)" && echo y)"
bash "$r/evals/run.sh" --bogus >/dev/null 2>&1; rc=$?
check "an unknown flag exits 2" test "$rc" -eq 2
EVALS_CHECK_TIMEOUT=x bash "$r/evals/run.sh" >/dev/null 2>&1; rc=$?
check "a bad EVALS_CHECK_TIMEOUT exits 2" test "$rc" -eq 2

echo "• evals/guard.sh (offline, temp repos)"
gr="$tmp/guard"
git -c init.defaultBranch=main init -q "$gr" || { echo "evals: git init failed" >&2; exit 1; }
gcommit() {
  git -C "$gr" add -A && git -C "$gr" -c user.name=t -c user.email=t@example.invalid \
    -c commit.gpgsign=false commit -q --no-verify -m "$1"
}
mkdir -p "$gr/evals"
cp "$T/evals/run.sh" "$T/evals/guard.sh" "$gr/evals/"
echo v1 >"$gr/app.txt"
eval_dir "$gr" old script 'grep -qx v1 "$1/app.txt"'
gcommit base || { echo "evals: git commit failed" >&2; exit 1; }
# pr <name> : start branch <name> from main.
pr() { git -C "$gr" checkout -q -B "$1" main; }
# guard [base] : run the guard from main's copy, on main (or <base>) and the current branch; sets
# out and rc.
guard() {
  git -C "$gr" show main:evals/guard.sh >"$tmp/guard.sh"
  out="$(cd "$gr" && bash "$tmp/guard.sh" "${1:-main}" HEAD 2>&1)"; rc=$?
}

pr add-mustfail
eval_dir "$gr" v2 script 'grep -qx v2 "$1/app.txt" || { echo "FAIL: app is not v2"; exit 1; }'
gcommit "add a must-fail eval"
guard
check "a PR adding a must-fail eval: passes" test "$rc" -eq 0 \
  -a -n "$(has "$out" "ok: evals/v2/ fails on the base (exit 1)" && echo y)"
pr add-passing
eval_dir "$gr" already script 'grep -qx v1 "$1/app.txt"'
gcommit "add an eval that already passes"
guard
check "a PR adding an eval that passes on the base: fails" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/already/check.sh passes on the base (main): a new eval \
must fail there first" && echo y)"
pr modify
printf '#!/usr/bin/env bash\nexit 0\n' >"$gr/evals/old/check.sh"
gcommit "weaken an eval"
guard
check "a PR modifying an eval: fails" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/old/check.sh: modifies an existing eval file" && echo y)"
pr delete
git -C "$gr" rm -rq evals/old
gcommit "delete an eval"
guard
check "a PR deleting an eval: fails, one line per file" test "$rc" -eq 1 \
  -a "$(printf '%s\n' "$out" | grep -c ': deletes (or renames) an existing eval file$')" -eq 2
pr rename
git -C "$gr" mv evals/old evals/renamed
gcommit "rename an eval"
guard
check "a PR renaming an eval: fails" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/old/check.sh: deletes (or renames) an existing eval file" \
    && echo y)"
pr modify-runner
echo '# tweak' >>"$gr/evals/run.sh"
gcommit "change the runner"
guard
check "a PR changing evals/run.sh: fails" test "$rc" -eq 1
pr add-into
echo fixture >"$gr/evals/old/extra.txt"
gcommit "add a file to an existing eval"
guard
check "a PR adding a file to an existing eval: fails" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/old/extra.txt: adds a file to the existing eval evals/old/" \
    && echo y)"
pr add-model
eval_dir "$gr" judged model
gcommit "add a model-judged eval"
guard
check "a PR adding a model-judged eval: format checked, not run, passes" test "$rc" -eq 0 \
  -a -n "$(has "$out" "ok: evals/judged/ (judge: model: format checked, not run)" && echo y)"
pr add-bad
eval_dir "$gr" Bad-Id script 'exit 1'
eval_dir "$gr" nocheck script
eval_dir "$gr" broken script 'if then'
gcommit "add malformed evals"
guard
check "malformed new evals: a bad id, no check.sh, a syntax error each fail" test "$rc" -eq 1 \
  -a "$(printf '%s\n' "$out" | grep -c '^FAIL: ')" -eq 3
# main gains an eval after the PR branched: the PR's own diff does not delete it.
pr behind
echo docs >"$gr/notes.txt"
gcommit "unrelated work"
git -C "$gr" checkout -q main
eval_dir "$gr" later script 'exit 1'
gcommit "main adds an eval"
git -C "$gr" checkout -q behind
guard
check "a PR branched before main added an eval: passes" test "$rc" -eq 0 \
  -a -n "$(has "$out" "evals-guard: 0 new eval(s), 0 problem(s)" && echo y)"
(cd "$gr" && bash "$T/evals/guard.sh" main) >/dev/null 2>&1; rc=$?
check "one ref only: exits 2" test "$rc" -eq 2
(cd "$gr" && bash "$T/evals/guard.sh" main no-such-ref) >/dev/null 2>&1; rc=$?
check "an unknown ref: exits 3" test "$rc" -eq 3

echo
echo "evals: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
