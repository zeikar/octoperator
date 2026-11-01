#!/usr/bin/env bash
# evals.sh — offline tests for the scenario-eval templates genesis copies into a new repo
# (skills/genesis/templates/evals/).
#
# Usage:
#   bash scripts/test/evals.sh
#
#   - run.sh   : against fixture evals that pass, fail, are skipped (judge: model), exit 2, time
#                out, or are malformed; the summary line, the exit code, and the evals-metric
#                notice only under GitHub Actions; and the attacks on it: a symlinked eval, a
#                check that writes into the repo (the run stops), one that leaves a process
#                behind, one that reads the CI environment, and one that prints workflow commands
#   - guard.sh : against throwaway git repos, a PR that adds a must-fail eval passes; one that adds
#                an eval already passing on the base, modifies, deletes, or renames an eval, or
#                adds a file to an existing eval fails; a model-judged eval is not run; an eval
#                the base gained after the PR branched is not read as deleted; and each attack the
#                PR #98 review reproduced: export-subst, a check that finds itself, .git, or the
#                CI environment, symlinks, submodules, top-level files, .gitattributes, control
#                characters, git replace refs (in the workflow's own step too), a shared or
#                polluted base tree, a check rewriting the running guard, and an export-ignore
#                on the base; --diff-only runs no check; --run-new and --verdict, as the
#                workflow's three jobs run them, and a forged or missing result
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
# run.sh checks the repo's git status around each check, so the fixture is a git work tree.
git -c init.defaultBranch=main init -q "$r" || { echo "evals: git init failed" >&2; exit 1; }
cp "$T/evals/run.sh" "$r/evals/run.sh"
echo v1 >"$r/app.txt"
# Tracked, as product code is: git status sees a check rewrite it.
git -C "$r" add app.txt && git -C "$r" -c user.name=t -c user.email=t@example.invalid \
  -c commit.gpgsign=false commit -q --no-verify -m app \
  || { echo "evals: git commit failed" >&2; exit 1; }
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
mkdir -p "$tmp/nogit/evals"
cp "$T/evals/run.sh" "$tmp/nogit/evals/"
bash "$tmp/nogit/evals/run.sh" >/dev/null 2>&1; rc=$?
check "a REPO_DIR outside any git work tree exits 2" test "$rc" -eq 2
rm -rf "$r/evals/nofile" "$r/evals/nojudge" "$r/evals/nocheck"
# A symlink in evals/ is never followed: it could count a check outside evals/, or one twice.
mkdir -p "$r/src/fake"
printf -- '---\nid: fake\njudge: script\nrequirement: R1\n---\n\nx\n' >"$r/src/fake/scenario.md"
printf '#!/usr/bin/env bash\nexit 0\n' >"$r/src/fake/check.sh"
ln -s ../src/fake "$r/evals/alias"
ln -s pass "$r/evals/twice"
out="$(GITHUB_ACTIONS=false bash "$r/evals/run.sh" 2>&1)"; rc=$?
check "symlinked evals (outside evals/, and a second name): each failed, never run" \
  test "$rc" -eq 1 -a -n "$(has "$out" "fail: alias (a symlink, not an eval directory)" \
    && has "$out" "fail: twice (a symlink, not an eval directory)" && has "$out" "pass: pass" \
    && has "$out" "evals: 1/3 passed (1 skipped)" && echo y)"
rm -rf "$r/evals/alias" "$r/evals/twice" "$r/src"
# A check sees only PATH and HOME: it can't tell CI's pull_request run from the push run.
eval_dir "$r" envy script '[ -z "${GITHUB_EVENT_NAME:-}${RUNNER_TEMP:-}" ]'
out="$(GITHUB_EVENT_NAME=push RUNNER_TEMP=/x GITHUB_ACTIONS=false bash "$r/evals/run.sh" 2>&1)"
check "a check runs under env -i: CI's variables are gone" has "$out" "pass: envy"
rm -rf "$r/evals/envy"
# A process a check leaves behind is killed when the check exits.
eval_dir "$r" lingers script '(sleep 1; echo late >"$1/../late.txt") </dev/null >/dev/null 2>&1 &
exit 1'
GITHUB_ACTIONS=false bash "$r/evals/run.sh" >/dev/null 2>&1
sleep 2
check "a process the check left running is killed with it" test ! -e "$tmp/late.txt"
rm -rf "$r/evals/lingers"
# A failing check's output can't issue workflow commands: it prints between stop-commands markers.
eval_dir "$r" inject script 'echo "::notice title=evals-metric::passed=99 total=99"; exit 1'
out="$(GITHUB_ACTIONS=true bash "$r/evals/run.sh" 2>&1)"
# live_commands <text> : the lines GitHub would run as workflow commands (leading space trimmed,
# as the runner does), outside any stop-commands block.
live_commands() {
  printf '%s\n' "$1" | awk '!tok && /^::stop-commands::/ { tok = substr($0, 18); next }
    tok && $0 == "::" tok "::" { tok = ""; next }
    !tok { l = $0; sub(/^[ \t]+/, "", l); if (l ~ /^::/) print l }'
}
check "a check's '::notice' output is inside a stop-commands block, with a random token" \
  test "$(live_commands "$out")" = "::notice title=evals-metric::passed=1 total=2" \
    -a -n "$(has "$out" "    ::notice title=evals-metric::passed=99 total=99" && \
      printf '%s\n' "$out" | grep -Eqx '::stop-commands::[0-9a-f]{32}' && echo y)"
rm -rf "$r/evals/inject"
# A check that writes into the repo could make the next eval pass: the run stops there.
eval_dir "$r" aaa script 'echo v2 >"$1/app.txt"; exit 1'
out="$(GITHUB_ACTIONS=true bash "$r/evals/run.sh" 2>&1)"; rc=$?
check "a check that changes the repo: failed, the run stops, no metric" test "$rc" -eq 1 \
  -a -n "$(has "$out" "fail: aaa (changed the repo it judges)" && has "$out" \
    "evals: aborted: aaa changed the repo it judges (its HEAD or git status)" && echo y)" \
  -a -z "$(printf '%s\n' "$out" | grep -e '^pass: ' -e 'evals-metric::passed=1' -e '^evals: [0-9]')"
echo v1 >"$r/app.txt"
eval_dir "$r" aaa script 'mkdir -p "$1/build"; : >"$1/build/out.txt"; exit 1'
printf 'build/\n' >"$r/.git/info/exclude"
out="$(GITHUB_ACTIONS=false bash "$r/evals/run.sh" 2>&1)"; rc=$?
check "a check that writes an ignored file into the repo: the run stops too" test "$rc" -eq 1 \
  -a -n "$(has "$out" "fail: aaa (changed the repo it judges)" && echo y)"
rm -rf "$r/evals/aaa" "$r/build"

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
# The attacks the PR #98 review reproduced. Each would have merged; each must now fail the guard.
# passes_on_base <id> : the guard's output says the new eval's check passed on the base.
passes_on_base() {
  has "$out" "FAIL: evals/$1/check.sh passes on the base (main): a new eval must fail there first"
}
pr subst-judge
eval_dir "$gr" sneaky script 'exit 0'
printf 'scenario.md export-subst\n' >"$gr/evals/sneaky/.gitattributes"
printf -- '---\nid: sneaky\nrequirement: R1\nx$Format:%%n$judge: model\njudge: script\n---\n\nx\n' \
  >"$gr/evals/sneaky/scenario.md"
gcommit "export-subst flips the judge in git archive's output"
guard
check "export-subst flipping judge: the .gitattributes fails, and the check runs (passes)" \
  test "$rc" -eq 1 -a -n "$(has "$out" "FAIL: evals/sneaky/.gitattributes: adds a .gitattributes, \
which changes how git checks out the eval" && passes_on_base sneaky && echo y)"
pr subst-detect
eval_dir "$gr" sneaky2 script "v='\$Format:Z\$'; [ \"\$v\" = Z ] && exit 1; exit 0"
printf 'check.sh export-subst\n' >"$gr/evals/sneaky2/.gitattributes"
gcommit "a check that detects git archive"
guard
check "a check that detects git archive: the base tree is a checkout, not an archive" \
  test "$rc" -eq 1 -a -n "$(passes_on_base sneaky2 && echo y)"
pr self
eval_dir "$gr" selfy script '[ -f "$1/evals/selfy/check.sh" ] || exit 1'
gcommit "a check that looks for itself"
guard
check "a check that looks for itself in the repo: the new evals are laid over the base" \
  test "$rc" -eq 1 -a -n "$(passes_on_base selfy && echo y)"
pr dotgit
eval_dir "$gr" gitty script '[ -d "$1/.git" ] || exit 1
[ -z "$(git -C "$1" status --porcelain)" ] || exit 1'
gcommit "a check that looks for .git"
guard
check "a check that looks for .git and a clean status: the base tree has both" \
  test "$rc" -eq 1 -a -n "$(passes_on_base gitty && echo y)"
pr ci-env
eval_dir "$gr" envy script '[ "${GITHUB_EVENT_NAME:-}" = pull_request ] && exit 1; exit 0'
gcommit "a check that reads the CI environment"
GITHUB_EVENT_NAME=pull_request guard
check "a check that reads GITHUB_EVENT_NAME: it runs under env -i" \
  test "$rc" -eq 1 -a -n "$(passes_on_base envy && echo y)"
# The stack's setup installs dependencies into the workspace, ignored: the base tree links them.
pr deps
eval_dir "$gr" needsdeps script '[ -f "$1/deps/lib.txt" ] || { echo "FAIL: no deps"; exit 3; }
[ -z "$(git -C "$1" status --porcelain)" ] || exit 4
grep -qx v2 "$1/app.txt" || exit 1'
gcommit "a check that needs the installed dependencies"
printf 'deps/\n' >"$gr/.git/info/exclude"
mkdir -p "$gr/deps" && echo lib >"$gr/deps/lib.txt"
guard
check "the workspace's ignored dependency directories are linked into the base tree" \
  test "$rc" -eq 0 -a -n "$(has "$out" "ok: evals/needsdeps/ fails on the base (exit 1)" && echo y)"
rm -rf "$gr/deps" && : >"$gr/.git/info/exclude"
pr symdir
mkdir -p "$gr/src/fake"
printf -- '---\nid: fake\njudge: script\nrequirement: R1\n---\n\nx\n' >"$gr/src/fake/scenario.md"
printf '#!/usr/bin/env bash\nexit 0\n' >"$gr/src/fake/check.sh"
ln -s ../src/fake "$gr/evals/alias"
ln -s old "$gr/evals/old2"
gcommit "symlinked evals"
guard
check "symlinked eval directories (outside evals/, and a second name): fail" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/alias: adds a symlink: evals hold regular files only" \
    && has "$out" "FAIL: evals/old2: adds a symlink: evals hold regular files only" && echo y)"
pr symfile
eval_dir "$gr" linked script 'exit 1'
ln -s ../../app.txt "$gr/evals/linked/fixture.txt"
gcommit "a symlink inside a new eval"
guard
check "a symlink inside a new eval: fails" test "$rc" -eq 1 -a -n "$(has "$out" \
  "FAIL: evals/linked/fixture.txt: adds a symlink: evals hold regular files only" && echo y)"
pr submodule
eval_dir "$gr" withsub script 'exit 1'
git -C "$gr" add -A
git -C "$gr" update-index --add \
  --cacheinfo "160000,$(git -C "$gr" rev-parse main),evals/withsub/mod"
# Not gcommit: its `add -A` would drop the gitlink, which has no directory in the work tree.
git -C "$gr" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q \
  --no-verify -m "a submodule inside a new eval"
guard
check "a submodule under evals/: fails" test "$rc" -eq 1 -a -n "$(has "$out" \
  "FAIL: evals/withsub/mod: adds a submodule: evals hold regular files only" && echo y)"
pr toplevel
echo notes >"$gr/evals/notes.md"
gcommit "a file directly under evals/"
guard
check "a file added directly under evals/: fails" test "$rc" -eq 1 -a -n "$(has "$out" \
  "FAIL: evals/notes.md: adds a file directly under evals/, outside an eval directory" && echo y)"
pr rootattrs
printf 'evals/old/check.sh ident\n' >"$gr/.gitattributes"
gcommit "a root .gitattributes"
guard
check "a change to the root .gitattributes: fails" test "$rc" -eq 1 -a -n "$(has "$out" \
  "FAIL: .gitattributes: changes how git checks out the evals (status A)" && echo y)"
pr ctrl
nl="evals/a
::notice title=evals-metric::passed=99 total=99"
mkdir -p "$gr/$nl" && echo x >"$gr/$nl/check.sh"
gcommit "a path with a newline"
guard
check "a path with a newline: fails, and prints no line of its own" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: a path under evals/ holds a control character (a newline, …)" \
    && echo y)" -a -z "$(printf '%s\n' "$out" | grep '^::')"
pr mode
chmod +x "$gr/evals/old/check.sh"
gcommit "a mode change only"
guard
check "a mode change to an eval file: fails" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/old/check.sh: modifies an existing eval file" && echo y)"
pr typechange
rm "$gr/evals/old/check.sh" && ln -s ../../app.txt "$gr/evals/old/check.sh"
gcommit "a file turned into a symlink"
guard
check "an eval file turned into a symlink: fails" test "$rc" -eq 1 -a -n "$(has "$out" \
  "FAIL: evals/old/check.sh: changes an existing eval file (status T)" && echo y)"
# Replace refs, as PR code run before the guard could plant: the guard never reads them.
pr replace
printf '#!/usr/bin/env bash\nexit 0\n' >"$gr/evals/old/check.sh"
gcommit "weaken an eval"
git -C "$gr" replace "$(git -C "$gr" rev-parse replace)" "$(git -C "$gr" rev-parse main)"
guard
check "a replace ref swapping the head for the base: the guard ignores it" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/old/check.sh: modifies an existing eval file" && echo y)"
git -C "$gr" replace -d "$(git -C "$gr" rev-parse replace)" >/dev/null
noop="$(git -C "$gr" -c user.name=t -c user.email=t@example.invalid commit-tree -p main \
  -m noop "main^{tree}")"
git -C "$gr" replace "$(git -C "$gr" rev-parse replace)" "$noop"
guard
check "a replace ref swapping the head for a no-op commit on the base: ignored" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/old/check.sh: modifies an existing eval file" && echo y)"
git -C "$gr" replace -d "$(git -C "$gr" rev-parse replace)" >/dev/null
# step_script <job> : the run: | block of a job in the evals-guard workflow template, unindented.
step_script() {
  awk -v job="  $1:" '$0 == job { injob = 1; next } injob && /^  [^ ]/ { injob = 0 }
    injob && /^        run: \|$/ { inrun = 1; next }
    inrun && /^          / { sub(/^          /, ""); print; next } { inrun = 0 }' \
    "$T/.github/workflows/evals-guard.yml"
}
# job <name> [base] : run that job's step as the workflow does, from $gr; sets out and rc.
job() {
  out="$(cd "$gr" && BASE_SHA="$(git rev-parse "${2:-main}")" HEAD_SHA="$(git rev-parse HEAD)" \
    RUNNER_TEMP="$tmp/rt" bash -c "$(step_script "$1")" 2>&1)"; rc=$?
}
fakeblob="$(printf 'echo fake guard; exit 0\n' | git -C "$gr" hash-object -w --stdin)"
fakebase="$(GIT_INDEX_FILE="$tmp/fake.idx" sh -c 'git -C "$1" read-tree main \
  && git -C "$1" update-index --cacheinfo "100644,$2,evals/guard.sh" && git -C "$1" write-tree' \
  _ "$gr" "$fakeblob")"
fakebase="$(git -C "$gr" -c user.name=t -c user.email=t@example.invalid commit-tree -m fake \
  "$fakebase")"
realbase="$(git -C "$gr" rev-parse main)"
git -C "$gr" replace "$realbase" "$fakebase"
job append-only "$realbase"
git -C "$gr" replace -d "$realbase" >/dev/null
check "the workflow's append-only step reads the real base guard past a replace ref" \
  test "$rc" -eq 1 -a -n "$(has "$out" "FAIL: evals/old/check.sh: modifies an existing eval file" \
    && echo y)" -a -z "$(printf '%s\n' "$out" | grep -F 'fake guard')"
check "the append-only step records the base it judged as a notice" \
  has "$out" "::notice title=evals-guard-base::$realbase"
# --diff-only runs nothing from the PR, so no setup step is needed before it.
pr diffonly
eval_dir "$gr" marker script "touch '$tmp/ran-marker'; exit 1"
gcommit "an eval whose check leaves a marker"
job append-only
check "the append-only job (--diff-only) passes a must-fail eval and runs no check" \
  test "$rc" -eq 0 -a ! -e "$tmp/ran-marker" \
    -a -n "$(has "$out" "evals-guard: 1 new eval(s), 0 problem(s)" && echo y)"
# The must-fail and verdict jobs, as the workflow runs them, sharing RUNNER_TEMP as the artifact.
job must-fail
check "the must-fail job (--run-new) runs the check and records its exit code" \
  test "$rc" -eq 0 -a -e "$tmp/ran-marker" \
    -a -n "$(grep -Fx 'marker 1' "$tmp/rt/must-fail/results.txt")"
job verdict
check "the verdict job (--verdict) passes it" test "$rc" -eq 0 \
  -a -n "$(has "$out" "ok: evals/marker/ fails on the base (exit 1)" && echo y)"
printf 'marker 0\n' >"$tmp/rt/must-fail/results.txt"
job verdict
check "the verdict job fails a recorded pass" test "$rc" -eq 1 -a -n "$(has "$out" \
  "FAIL: evals/marker/check.sh passes on the base ($realbase): a new eval must fail there first" \
  && echo y)"
printf 'other 1\nmarker x1\n' >"$tmp/rt/must-fail/results.txt"
job verdict
check "the verdict job fails a garbled result" test "$rc" -eq 1 -a -n "$(has "$out" \
  "FAIL: evals/marker/check.sh: an unreadable must-fail result" && echo y)"
printf 'marker modified\n' >"$tmp/rt/must-fail/results.txt"
job verdict
check "the verdict job fails a check that changed the tree" test "$rc" -eq 1 -a -n "$(has "$out" \
  "FAIL: evals/marker/check.sh changes the repo it judges: a check must leave <repo-dir> as it \
found it" && echo y)"
rm -f "$tmp/rt/must-fail/results.txt"
job verdict
check "the verdict job fails a new script eval with no result" test "$rc" -eq 1 -a -n "$(has \
  "$out" "FAIL: evals/marker/check.sh: no must-fail result: it did not run on the base" && echo y)"
rm -rf "$tmp/rt" "$tmp/ran-marker"
# A must-fail check that changes its tree could make another pass on main: each gets a fresh tree,
# and a change fails the eval.
pr pollute
eval_dir "$gr" aaa script 'rm -f "$1/app.txt"; exit 1'
eval_dir "$gr" bbb script 'grep -qx v1 "$1/app.txt"'
eval_dir "$gr" ccc script 'echo v2 >"$1/app.txt"; exit 1'
gcommit "checks that change their tree"
guard
check "checks that change their tree fail, and a later check gets a fresh tree" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/aaa/check.sh changes the repo it judges: a check must leave \
<repo-dir> as it found it" && has "$out" "FAIL: evals/ccc/check.sh changes the repo it judges: a \
check must leave <repo-dir> as it found it" && passes_on_base bbb && echo y)"
# A check that rewrites the running guard in place (bash reads a script as it runs it): it cuts
# the guard's last summary line and appends a verdict of its own. The guard is parsed whole, up to
# its last line, before anything runs.
pr rewrite
printf '#!/usr/bin/env bash\nexit 0\n' >"$gr/evals/old/check.sh"
eval_dir "$gr" zzz script "perl -e 'open(F, \"+<\", \$ARGV[0]) or die; local \$/; \$s = <F>;
  \$s =~ s/^echo \"evals-guard:.*\\z//ms;
  \$s .= \"echo \\\"evals-guard: looks fine\\\"; exit 0\\n\";
  seek(F, 0, 0); print F \$s; truncate(F, tell(F)); close F' '$tmp/guard.sh'
exit 1"
gcommit "weaken an eval, and rewrite the guard from a check"
guard
check "a check that rewrites the running guard file: the verdict stands" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/old/check.sh: modifies an existing eval file" && echo y)" \
  -a -z "$(printf '%s\n' "$out" | grep -F 'looks fine')" \
  -a -n "$(grep -F 'looks fine' "$tmp/guard.sh")"
(cd "$gr" && bash "$T/evals/guard.sh" main) >/dev/null 2>&1; rc=$?
check "one ref only: exits 2" test "$rc" -eq 2
(cd "$gr" && bash "$T/evals/guard.sh" main no-such-ref) >/dev/null 2>&1; rc=$?
check "an unknown ref: exits 3" test "$rc" -eq 3
# Last, since it changes main: an export-ignore on the base hid product code from git archive.
git -C "$gr" checkout -q main
printf 'app.txt export-ignore\n' >"$gr/.gitattributes"
gcommit "an export-ignore on the base"
pr expign
eval_dir "$gr" already2 script 'grep -qx v1 "$1/app.txt"'
gcommit "an eval that passes on the base, where app.txt is export-ignore"
guard
check "the base's export-ignore files are in the base tree: an eval passing there fails" \
  test "$rc" -eq 1 -a -n "$(passes_on_base already2 && echo y)"

echo
echo "evals: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
