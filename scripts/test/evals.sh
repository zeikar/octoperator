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
#                behind, one that reads the CI environment, and one that prints workflow commands;
#                under Actions only, an evals/ that differs from the commit (an ignored file
#                there too) stops the run first; skipped model evals never change its exit code
#                and never reach curl
#   - run.sh --evidence / --judge and judge.sh : against a fake curl first on PATH (no network, no
#                real key): a PASS reply passes, FAIL fails, and any other reply (extra words,
#                lowercase, two blocks, an HTTP error) fails; --evidence runs the checks with no
#                key and no cap, calls nothing, writes one <id>.txt per eval with evidence (none
#                for a failed or silent check), refuses a non-empty DIR, and fails when it has no
#                evidence at all; --judge runs no check, needs the call cap (EVALS_MAX_CALLS), the
#                key, and a valid EVALS_MAX_EVIDENCE_BYTES, takes its eval list from its own
#                checkout, fails an eval whose file is missing, a symlink, a directory, empty, or
#                over the byte cap (200000 by default) without a call, ignores extra files, and
#                once the cap is used fails the evals left uncalled; the prompt holds the scenario
#                and the evidence; the key goes only into a header file, never into curl's
#                arguments or any output; and the template's two jobs, run as the workflow runs
#                them, with the judge step's pinned env and a planted artifact file
#   - guard.sh : against throwaway git repos, a PR that adds a must-fail eval passes; one that adds
#                an eval already passing on the base, modifies, deletes, or renames an eval, or
#                adds a file to an existing eval fails; a model-judged eval is not run, but
#                needs a check.sh that parses; an eval
#                the base gained after the PR branched is not read as deleted; and each attack the
#                PR #98 review reproduced: export-subst, a check that finds itself, .git, or the
#                CI environment, symlinks, submodules, top-level files, .gitattributes, control
#                characters, git replace refs (in the workflow's own step too), a shared or
#                polluted base tree, a check rewriting the running guard, and an export-ignore
#                on the base; --diff-only runs no check; --run-new and --verdict, as the
#                workflow's three jobs run them (the base from checkout's origin/<base branch>),
#                a forged or missing result, a base that moved between must-fail and verdict
#                (fails a PR that changes evals/, passes one that doesn't, fails closed with no
#                merge base), and a base with no evals/guard.sh or no fetched base branch (each job fails)
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
# commit_evals : commit evals/ as it is now. Under Actions, run.sh stops when evals/ differs from
# the commit, so each run with GITHUB_ACTIONS=true commits the fixture first.
commit_evals() {
  git -C "$r" add -A evals && git -C "$r" -c user.name=t -c user.email=t@example.invalid \
    -c commit.gpgsign=false commit -q --no-verify --allow-empty -m evals \
    || { echo "evals: git commit failed" >&2; exit 1; }
}
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
commit_evals
out="$(GITHUB_ACTIONS=true bash "$r/evals/run.sh" 2>&1)"
check "under GitHub Actions: the evals-metric notice" \
  has "$out" "::notice title=evals-metric::passed=1 total=3"
# Under Actions the setup ran the repo's code (a postinstall) before run.sh: an evals/ it changed
# stops the run before any check, with no metric.
printf '#!/usr/bin/env bash\nexit 0\n' >"$r/evals/fail/check.sh"
mkdir -p "$r/evals/planted" && : >"$r/evals/planted/check.sh"
out="$(GITHUB_ACTIONS=true bash "$r/evals/run.sh" 2>&1)"; rc=$?
check "under Actions, a check rewritten before the run: stops, runs nothing, no metric" \
  test "$rc" -eq 1 -a -n "$(has "$out" \
    "evals: aborted: evals/ differs from the commit before any check ran (git status)" \
    && has "$out" "     M evals/fail/check.sh" && has "$out" "    ?? evals/planted/check.sh" \
    && echo y)" \
    -a -z "$(printf '%s\n' "$out" | grep -e '^pass: ' -e '^fail: ' -e 'evals-metric')"
out="$(GITHUB_ACTIONS=false bash "$r/evals/run.sh" 2>&1)"
check "outside Actions, an eval being written runs as it is" has "$out" "pass: fail"
git -C "$r" checkout -q -- evals && rm -rf "$r/evals/planted"
# An eval planted where .gitignore hides it is still a difference from the commit.
printf 'evals/hidden/\n' >"$r/.git/info/exclude"
eval_dir "$r" hidden script 'exit 0'
out="$(GITHUB_ACTIONS=true bash "$r/evals/run.sh" 2>&1)"; rc=$?
check "under Actions, an ignored eval planted before the run: stops, runs nothing" \
  test "$rc" -eq 1 -a -n "$(has "$out" \
    "evals: aborted: evals/ differs from the commit before any check ran (git status)" \
    && has "$out" "    !! evals/hidden/check.sh" && echo y)" \
    -a -z "$(printf '%s\n' "$out" | grep -e '^pass: ' -e 'evals-metric')"
rm -rf "$r/evals/hidden" && : >"$r/.git/info/exclude"
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
commit_evals
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
commit_evals
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

echo "• evals/run.sh --evidence / --judge and evals/judge.sh (offline, a fake curl)"
# The fake curl answers from the request body: a marker in the evidence picks the reply. It logs
# its arguments and the header file, so the tests see what a real call would have sent.
fake="$tmp/fake-bin"
mkdir -p "$fake" || { echo "evals: mkdir failed" >&2; exit 1; }
cat >"$fake/curl" <<CURL
#!/usr/bin/env bash
out="" hdr="" body=""
printf '%s\n' "\$*" >>"$tmp/curl.args"
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -H) hdr="\${2#@}"; shift 2 ;;
    --data-binary) body="\${2#@}"; shift 2 ;;
    *) shift ;;
  esac
done
cat "\$hdr" >>"$tmp/curl.headers"
cp "\$body" "$tmp/curl.body"
reply() { printf '{"content":[{"type":"text","text":"%s"}]}' "\$1" >"\$out"; printf 200; }
case "\$(cat "\$body")" in
  *say-pass*) reply ' PASS\\n' ;;
  *say-fail*) reply FAIL ;;
  *say-junk*) reply 'PASS, mostly' ;;
  *say-lower*) reply pass ;;
  *say-two*) printf '{"content":[{"type":"text","text":"PASS"},{"type":"text","text":"PASS"}]}' \
    >"\$out"; printf 200 ;;
  *say-http*) printf '{"type":"error","error":{"type":"authentication_error"}}' >"\$out"
    printf 401 ;;
  *) reply '' ;;
esac
CURL
chmod +x "$fake/curl"
KEY=sk-test-not-a-real-key-0123456789
# calls : how many times the fake curl ran.
calls() { if [ -f "$tmp/curl.args" ]; then grep -c '' "$tmp/curl.args"; else echo 0; fi; }
# judge <evidence marker> : run judge.sh on a prompt holding the marker; sets out and rc.
judge() {
  printf 'Scenario:\nThe tone holds.\n\nEvidence:\n%s\n' "$1" >"$tmp/prompt.txt"
  out="$(PATH="$fake:$PATH" ANTHROPIC_API_KEY="$KEY" bash "$T/evals/judge.sh" "$tmp/prompt.txt" \
    2>&1)"; rc=$?
}
[ "$(PATH="$fake:$PATH" command -v curl)" = "$fake/curl" ] \
  || { echo "evals: the fake curl is not first on PATH" >&2; exit 1; }
judge say-pass
check "judge.sh, a PASS reply (whitespace around it): prints PASS, exits 0" \
  test "$rc" -eq 0 -a "$out" = PASS
judge say-fail
check "judge.sh, a FAIL reply: prints FAIL, exits 1" test "$rc" -eq 1 -a "$out" = FAIL
for m in say-junk say-lower say-two empty; do
  judge "$m"
  check "judge.sh, not exactly PASS or FAIL ($m): a failure, exits 1" test "$rc" -eq 1 \
    -a "${out%% *}" = "error:"
done
judge say-http
check "judge.sh, an HTTP error: a failure, exits 1, the error type only" test "$rc" -eq 1 \
  -a "$out" = "error: HTTP 401 (authentication_error)"
check "judge.sh calls the Messages API with the default model" test -n "$(grep -F \
  'https://api.anthropic.com/v1/messages' "$tmp/curl.args" | head -n 1)" -a "$(jq -r .model \
  "$tmp/curl.body")" = claude-sonnet-5-5
check "judge.sh sends the key, the version, and the content type as headers" test -n "$(has \
  "$(cat "$tmp/curl.headers")" "x-api-key: $KEY" && has "$(cat "$tmp/curl.headers")" \
  "anthropic-version: 2023-06-01" && has "$(cat "$tmp/curl.headers")" \
  "content-type: application/json" && echo y)"
check "the key is never in curl's arguments" test -z "$(grep -F "$KEY" "$tmp/curl.args")"
n="$(calls)"
out="$(PATH="$fake:$PATH" env -u ANTHROPIC_API_KEY bash "$T/evals/judge.sh" "$tmp/prompt.txt" \
  2>&1)"; rc=$?
check "judge.sh with no key: exits 2, no call" \
  test "$rc" -eq 2 -a "$(calls)" -eq "$n" -a "$out" = "error: ANTHROPIC_API_KEY is not set"

m="$tmp/model"
mkdir -p "$m/evals"
git -c init.defaultBranch=main init -q "$m" || { echo "evals: git init failed" >&2; exit 1; }
cp "$T/evals/run.sh" "$T/evals/judge.sh" "$m/evals/"
eval_dir "$m" a-good model 'echo "user: hi"; echo "bot: hello, say-pass"'
eval_dir "$m" b-bad model 'echo "bot: say-fail"'
eval_dir "$m" c-broken model 'echo "FAIL: no transcript" >&2; exit 1'
eval_dir "$m" d-silent model 'exit 0'
eval_dir "$m" e-script script 'exit 0'
# model_run [args...] : run.sh with the fake curl first on PATH; sets out and rc. The key and the
# caps come from the caller's environment.
model_run() {
  out="$(PATH="$fake:$PATH" GITHUB_ACTIONS="${GA:-false}" bash "$m/evals/run.sh" "$@" 2>&1)"; rc=$?
}
# nofile <id> : the line --judge prints for an eval with no evidence file.
nofile() { echo "fail: $1 (no evidence file $1.txt: the evidence job's log says why)"; }
# files <dir> : the names in the directory, sorted, on one line.
files() { (cd "$1" && ls -A | LC_ALL=C sort | paste -sd ' ' -); }
rm -f "$tmp/curl.args" "$tmp/curl.headers"
ANTHROPIC_API_KEY="$KEY" model_run
check "offline run.sh: model evals skipped, exit 0 from the script eval alone, no model call" \
  test "$rc" -eq 0 -a "$(calls)" -eq 0 -a -n "$(has "$out" "evals: 1/1 passed (4 skipped)" \
    && has "$out" "skip: a-good (judge: model)" && echo y)"

# --evidence: the evidence job. It runs the checks, holds no key, and calls nothing.
ev="$tmp/evidence"
model_run --evidence
check "--evidence with no DIR: exits 2" test "$rc" -eq 2
mkdir -p "$tmp/leftover" && echo old >"$tmp/leftover/a-good.txt"
model_run --evidence "$tmp/leftover"
check "--evidence into a directory with a file in it: exits 2, writes nothing" \
  test "$rc" -eq 2 -a "$(cat "$tmp/leftover/a-good.txt")" = old
env -u ANTHROPIC_API_KEY -u EVALS_MAX_CALLS PATH="$fake:$PATH" bash "$m/evals/run.sh" \
  --evidence "$ev" >"$tmp/ev.out" 2>&1; rc=$?; out="$(cat "$tmp/ev.out")"
check "--evidence, no key, no cap: each model eval's evidence, failed checks named, no call" \
  test "$rc" -eq 0 -a "$(calls)" -eq 0 -a -n "$(has "$out" "evidence: a-good" \
    && has "$out" "evidence: b-bad" && has "$out" "fail: c-broken (exit 1)" \
    && has "$out" "    FAIL: no transcript" \
    && has "$out" "fail: d-silent (check.sh printed no evidence)" \
    && has "$out" "skip: e-script (judge: script)" \
    && has "$out" "evals: evidence for 2/4 model evals (1 skipped)" && echo y)"
check "--evidence writes one <id>.txt per eval with evidence, the check's stdout" \
  test "$(files "$ev")" = "a-good.txt b-bad.txt" -a "$(cat "$ev/a-good.txt")" = "user: hi
bot: hello, say-pass"
# A DIR inside the repo: written only after the last check, so no check sees the repo changed.
model_run --evidence "$m/out"
check "--evidence into a directory in the repo: no eval reads it as a change" \
  test "$rc" -eq 0 -a "$(files "$m/out")" = "a-good.txt b-bad.txt"
rm -rf "$m/out"
n1="$tmp/none"
mkdir -p "$n1/evals"
git -c init.defaultBranch=main init -q "$n1" || { echo "evals: git init failed" >&2; exit 1; }
cp "$T/evals/run.sh" "$n1/evals/"
eval_dir "$n1" only-broken model 'exit 1'
out="$(bash "$n1/evals/run.sh" --evidence "$tmp/none-ev" 2>&1)"; rc=$?
check "--evidence with no evidence at all: exits 1, writes nothing for the judge" \
  test "$rc" -eq 1 -a -z "$(files "$tmp/none-ev")" \
    -a -n "$(has "$out" "evals: evidence for 0/1 model evals (0 skipped)" && echo y)"

# --judge: the judge job. It runs no check, and spends only within the caps.
out="$(PATH="$fake:$PATH" ANTHROPIC_API_KEY="$KEY" env -u EVALS_MAX_CALLS \
  bash "$m/evals/run.sh" --judge "$ev" 2>&1)"; rc=$?
check "--judge with no EVALS_MAX_CALLS: exits 2, no call" test "$rc" -eq 2 -a "$(calls)" -eq 0
EVALS_MAX_CALLS=0 ANTHROPIC_API_KEY="$KEY" model_run --judge "$ev"
check "--judge with EVALS_MAX_CALLS=0: exits 2, no call" test "$rc" -eq 2 -a "$(calls)" -eq 0
out="$(PATH="$fake:$PATH" EVALS_MAX_CALLS=5 env -u ANTHROPIC_API_KEY \
  bash "$m/evals/run.sh" --judge "$ev" 2>&1)"; rc=$?
check "--judge with no key: exits 2, no call" test "$rc" -eq 2 -a "$(calls)" -eq 0
for b in 0 abc; do
  EVALS_MAX_CALLS=5 EVALS_MAX_EVIDENCE_BYTES="$b" ANTHROPIC_API_KEY="$KEY" model_run --judge "$ev"
  check "--judge with EVALS_MAX_EVIDENCE_BYTES=$b: exits 2, no call" \
    test "$rc" -eq 2 -a "$(calls)" -eq 0
done
EVALS_MAX_CALLS=5 ANTHROPIC_API_KEY="$KEY" model_run --judge "$tmp/no-such-dir"
check "--judge with no evidence directory: exits 2, no call" test "$rc" -eq 2 -a "$(calls)" -eq 0
# A check that would leave a marker: --judge must never run one.
eval_dir "$m" f-marker model "touch '$tmp/judge-ran-a-check'; echo say-pass"
EVALS_MAX_CALLS=10 ANTHROPIC_API_KEY="$KEY" model_run --judge "$ev"
check "--judge: PASS passes, FAIL fails, an eval with no evidence fails uncalled, script skipped" \
  test "$rc" -eq 1 -a "$(calls)" -eq 2 -a -n "$(has "$out" "pass: a-good" \
    && has "$out" "fail: b-bad (judge: FAIL)" \
    && has "$out" "$(nofile c-broken)" \
    && has "$out" "$(nofile d-silent)" \
    && has "$out" "$(nofile f-marker)" \
    && has "$out" "skip: e-script (judge: script)" && has "$out" "evals: 1/5 passed (1 skipped)" \
    && has "$out" "evals: model calls: 2/10" && echo y)"
check "--judge runs no check" test ! -e "$tmp/judge-ran-a-check"
rm -rf "$m/evals/f-marker"
check "the prompt holds the scenario's text, then the evidence" \
  test "$(jq -r '.messages[0].content' "$tmp/curl.body")" = "Scenario:

The scenario.

Evidence:
bot: say-fail"
check "the key never shows in run.sh's output" test -z "$(printf '%s\n' "$out" | grep -F "$KEY")"
rm -f "$tmp/curl.args"
EVALS_MAX_CALLS=1 ANTHROPIC_API_KEY="$KEY" model_run --judge "$ev"
check "--judge, the call cap used: the evals left fail uncalled" test "$rc" -eq 1 \
  -a "$(calls)" -eq 1 -a -n "$(has "$out" "pass: a-good" \
    && has "$out" "fail: b-bad (call cap reached: EVALS_MAX_CALLS=1)" \
    && has "$out" "evals: model calls: 1/1" && echo y)"

# The artifact is data from a job that ran the repo's code: it names no eval and widens nothing.
# Extra files (an id this checkout lacks, a script eval's id, a name with no .txt) are ignored; a
# symlink, a directory, or an empty file fails that eval uncalled.
bad="$tmp/bad-evidence"
mkdir -p "$bad/c-broken.txt"
echo "bot: say-pass" >"$bad/a-good.txt"
ln -s a-good.txt "$bad/b-bad.txt"
: >"$bad/d-silent.txt"
for x in x-new e-script zz-1 zz-2 zz-3; do echo "bot: say-pass" >"$bad/$x.txt"; done
echo "bot: say-pass" >"$bad/a-good"
rm -f "$tmp/curl.args"
EVALS_MAX_CALLS=10 ANTHROPIC_API_KEY="$KEY" model_run --judge "$bad"
check "--judge, a tampered artifact: one call, for the one real evidence file" \
  test "$rc" -eq 1 -a "$(calls)" -eq 1 -a -n "$(has "$out" "pass: a-good" \
    && has "$out" "$(nofile b-bad)" \
    && has "$out" "$(nofile c-broken)" \
    && has "$out" "fail: d-silent (evidence file d-silent.txt is empty)" \
    && has "$out" "evals: 1/4 passed (1 skipped)" && echo y)" \
    -a -z "$(printf '%s\n' "$out" | grep -e x-new -e zz- -e 'pass: e-script')"
# The evidence byte cap: over it, the eval fails before any call; at it, the call is made.
cap="$tmp/cap-evidence"
mkdir -p "$cap"
printf 'say-pass %041d' 0 >"$cap/a-good.txt"
printf 'say-pass %042d' 0 >"$cap/b-bad.txt"
rm -f "$tmp/curl.args"
EVALS_MAX_CALLS=10 EVALS_MAX_EVIDENCE_BYTES=50 ANTHROPIC_API_KEY="$KEY" model_run --judge "$cap"
check "--judge: evidence at EVALS_MAX_EVIDENCE_BYTES is sent, one byte over fails uncalled" \
  test "$(wc -c <"$cap/a-good.txt" | tr -d ' ')" -eq 50 -a "$rc" -eq 1 -a "$(calls)" -eq 1 \
    -a -n "$(has "$out" "pass: a-good" \
    && has "$out" "fail: b-bad (evidence over EVALS_MAX_EVIDENCE_BYTES=50 bytes)" && echo y)"
head -c 200001 /dev/zero | tr '\0' x >"$cap/a-good.txt"
rm -f "$tmp/curl.args" "$cap/b-bad.txt"
EVALS_MAX_CALLS=10 ANTHROPIC_API_KEY="$KEY" model_run --judge "$cap"
check "--judge: the byte cap defaults to 200000" test "$rc" -eq 1 -a "$(calls)" -eq 0 \
  -a -n "$(has "$out" "fail: a-good (evidence over EVALS_MAX_EVIDENCE_BYTES=200000 bytes)" \
    && echo y)"

# The workflow's two jobs, as the template runs them: the evidence step, then the judge step with
# the template's own env (its cap, byte cap, and model) and a fresh copy of the artifact.
git -C "$m" add -A && git -C "$m" -c user.name=t -c user.email=t@example.invalid \
  -c commit.gpgsign=false commit -q --no-verify -m evals \
  || { echo "evals: git commit failed" >&2; exit 1; }
MWF="$T/.github/workflows/evals-model.yml"
# model_step <job> : the `- run:` command of that job in the evals-model.yml template.
model_step() {
  awk -v job="  $1:" '/^  [^ #]/ { in_job = ($0 == job) }
    in_job && /^      - run: / { sub(/^      - run: /, ""); print }' "$MWF"
}
# model_env : the judge step's env, KEY=value per line, the model key's line left out.
model_env() {
  awk '/^        env:$/ { e = 1; next } e && /^          [A-Z_]+: / { k = $1; sub(/:$/, "", k)
      v = $0; sub(/^ *[A-Z_]+: /, "", v); print k "=" v; next } { e = 0 }' "$MWF" \
    | grep -v '^ANTHROPIC_API_KEY='
}
check "the template's judge step pins EVALS_MAX_CALLS, EVALS_MAX_EVIDENCE_BYTES, and EVALS_MODEL" \
  test "$(model_env | sed 's/=.*//' | paste -sd ' ' -)" = \
    "EVALS_MAX_CALLS EVALS_MAX_EVIDENCE_BYTES EVALS_MODEL"
rm -rf "$tmp/rt" "$tmp/rt2" "$tmp/curl.args"
out="$(cd "$m" && env -u ANTHROPIC_API_KEY PATH="$fake:$PATH" GITHUB_ACTIONS=true \
  RUNNER_TEMP="$tmp/rt" bash -c "$(model_step evidence)" 2>&1)"; rc=$?
check "the evidence job's step writes the artifact, no call" test "$rc" -eq 0 -a "$(calls)" -eq 0 \
  -a "$(files "$tmp/rt/evidence")" = "a-good.txt b-bad.txt"
mkdir -p "$tmp/rt2" && cp -R "$tmp/rt/evidence" "$tmp/rt2/evidence" \
  && echo "bot: say-pass" >"$tmp/rt2/evidence/planted.txt" \
  || { echo "evals: cp failed" >&2; exit 1; }
out="$(cd "$m" && while IFS= read -r kv; do export "${kv?}"; done <<<"$(model_env)" \
  && PATH="$fake:$PATH" ANTHROPIC_API_KEY="$KEY" GITHUB_ACTIONS=true RUNNER_TEMP="$tmp/rt2" \
  bash -c "$(model_step judge)" 2>&1)"; rc=$?
check "the judge job's step judges the evals with the template's cap and model" \
  test "$rc" -eq 1 -a "$(calls)" -eq 2 -a -n "$(has "$out" "pass: a-good" \
    && has "$out" "fail: b-bad (judge: FAIL)" \
    && has "$out" "evals: model calls: 2/$(model_env | sed -n 's/^EVALS_MAX_CALLS=//p')" \
    && echo y)" -a "$(jq -r .model "$tmp/curl.body")" = \
    "$(model_env | sed -n 's/^EVALS_MODEL=//p')" \
    -a -z "$(printf '%s\n' "$out" | grep -e planted -e 'evals-metric')"

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
eval_dir "$gr" judged model "touch '$tmp/model-ran'; echo transcript"
gcommit "add a model-judged eval"
guard
check "a PR adding a model-judged eval: format checked, not run, passes" test "$rc" -eq 0 \
  -a ! -e "$tmp/model-ran" \
  -a -n "$(has "$out" "ok: evals/judged/ (judge: model: format checked, not run)" && echo y)"
pr add-model-bad
eval_dir "$gr" nojudgecheck model
eval_dir "$gr" brokenjudge model 'if then'
gcommit "add model-judged evals without a check.sh, or with a broken one"
guard
check "a model-judged eval with no check.sh, or one that doesn't parse: fails" test "$rc" -eq 1 \
  -a -n "$(has "$out" "FAIL: evals/nojudgecheck/: a judge: model eval needs check.sh" \
    && printf '%s\n' "$out" | grep -q '^FAIL: evals/brokenjudge/check.sh: syntax error' \
    && echo y)"
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
# job <name> [base] : run that job's step as the workflow does, from $gr, with the base (main
# by default) as checkout's fetched origin/main; sets out and rc.
job() {
  git -C "$gr" update-ref refs/remotes/origin/main "${2:-main}" \
    || { echo "evals: git update-ref failed" >&2; exit 1; }
  out="$(cd "$gr" && GITHUB_BASE_REF=main HEAD_SHA="$(git rev-parse HEAD)" \
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
check "the must-fail job records the base it used in the artifact" \
  test "$(cat "$tmp/rt/must-fail/base.txt")" = "$realbase"
job verdict
check "the verdict job (--verdict) passes it" test "$rc" -eq 0 \
  -a -n "$(has "$out" "ok: evals/marker/ fails on the base (exit 1)" \
    && has "$out" "::notice title=evals-guard-base::$realbase" && echo y)"
# The base branch moved between must-fail and verdict: verdict's own fetch sees another tip.
job verdict "$(git -C "$gr" rev-parse main~1)"
check "the verdict job fails when must-fail judged another base" test "$rc" -eq 1 -a -n "$(has \
  "$out" "::error::must-fail judged another base: re-run all jobs" && echo y)" \
  -a -z "$(printf '%s\n' "$out" | grep -e '^ok: ' -e 'evals-guard-base')"
# A base with no evals/guard.sh, or no fetched base branch: each job fails, never passes empty.
noguard="$(git -C "$gr" -c user.name=t -c user.email=t@example.invalid commit-tree -p main \
  -m "no guard" "$(git -C "$gr" mktree </dev/null)")"
for j in append-only must-fail verdict; do
  echo "$noguard" >"$tmp/rt/must-fail/base.txt"
  job "$j" "$noguard"
  check "the $j job fails on a base without evals/guard.sh" test "$rc" -eq 1 \
    -a -n "$(has "$out" "::error::no evals/guard.sh at $noguard" && echo y)"
  out="$(cd "$gr" && GITHUB_BASE_REF=no-such-branch HEAD_SHA="$(git rev-parse HEAD)" \
    RUNNER_TEMP="$tmp/rt" bash -c "$(step_script "$j")" 2>&1)"; rc=$?
  check "the $j job fails with no fetched base branch" test "$rc" -eq 1 \
    -a -n "$(has "$out" "::error::no fetched tip for the base branch no-such-branch" && echo y)"
done
job must-fail
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
# A PR that changes nothing the guard reads gives it nothing to judge on any base: a base that
# moved between must-fail and verdict does not hold it.
pr appchange
echo v2 >"$gr/app.txt"
gcommit "a product change only"
job must-fail
git -C "$gr" rev-parse main~1 >"$tmp/rt/must-fail/base.txt"
job verdict
check "the verdict job passes a PR that changes no evals when must-fail judged another base" \
  test "$rc" -eq 0 -a -n "$(has "$out" "::notice title=evals-guard-base::$realbase" \
    && has "$out" "evals-guard: 0 new script eval(s) judged, 0 problem(s)" && echo y)"
# That exemption fails closed: with no merge base, verdict can't tell what the PR changes.
orphan="$(git -C "$gr" -c user.name=t -c user.email=t@example.invalid commit-tree -m orphan \
  "main^{tree}")"
git -C "$gr" checkout -q --detach "$orphan"
job verdict
check "the verdict job fails when must-fail judged another base and there is no merge base" \
  test "$rc" -eq 1 -a -n "$(has "$out" "::error::no merge base of $realbase and $orphan" \
    && echo y)" -a -z "$(printf '%s\n' "$out" | grep -e 'evals-guard-base')"
rm -rf "$tmp/rt"
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
