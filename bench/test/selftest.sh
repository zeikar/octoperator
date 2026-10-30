#!/usr/bin/env bash
# selftest.sh — prove bench/validate.sh catches broken benchmark tasks.
#
# Usage:
#   bench/test/selftest.sh
#
# Copies the real tasks into a `mktemp -d` directory, breaks one copy per case (a check that
# always passes or always fails, a patch that does not apply, a malformed task.md, a missing
# seed/, failing seed tests, a check that hangs), and asserts validate.sh exits 1 for each, with
# the expected reason, and 0 for the intact copy.
# Also covers its argument handling (--help, unknown argument, missing value, unknown task).
# Offline: no claude, gh, or network. Exits 0 when every check passes, 1 when any check fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BENCH="$(cd "$HERE/.." && pwd)"
VALIDATE="$BENCH/validate.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ✓ $1"; }
no() { fail=$((fail + 1)); echo "  ✗ $1"; }

# expect <wanted-exit> <label> <command...>
expect() {
  wanted="$1"; label="$2"; shift 2
  "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$wanted" ]; then ok "$label (exit $rc)"
  else no "$label (wanted $wanted, got $rc)"; fi
}

# No `set -e`: bail out explicitly, or an empty $tmp would point the copies at the real tree.
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "selftest: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

shopt -s nullglob
tasks=("$BENCH"/tasks/*/)
if [ "${#tasks[@]}" -eq 0 ]; then
  echo "selftest: no tasks found in $BENCH/tasks" >&2
  exit 1
fi
# The broken cases each corrupt a copy of the first task; which one does not matter.
sample="$(basename "${tasks[0]}")"

# broken_case <name> : a tasks dir at $tmp/<name> holding one intact copy of the sample task;
# prints the copy's path for the caller to corrupt.
broken_case() {
  mkdir -p "$tmp/$1" && cp -R "$BENCH/tasks/$sample" "$tmp/$1/" && echo "$tmp/$1/$sample"
}
# validates <tasks-dir> [args...] : run validate.sh against a tasks dir, quickly timing out checks.
validates() {
  tasks_dir="$1"; shift
  BENCH_CHECK_TIMEOUT=3 bash "$VALIDATE" --tasks "$tasks_dir" "$@"
}

echo "• validate.sh arguments"
help_header="$(awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$VALIDATE")"
expect 0 "--help shows the usage block only" \
  test "$(bash "$VALIDATE" --help 2>/dev/null)" = "$help_header"
expect 2 "unknown argument exits 2" bash "$VALIDATE" --bogus
expect 2 "--tasks without a value exits 2" bash "$VALIDATE" --tasks
expect 2 "missing tasks dir exits 2" bash "$VALIDATE" --tasks "$tmp/nope"
expect 2 "unknown task id exits 2" bash "$VALIDATE" no-such-task
expect 2 "non-numeric BENCH_CHECK_TIMEOUT exits 2" env BENCH_CHECK_TIMEOUT=x bash "$VALIDATE"

echo "• intact tasks"
mkdir -p "$tmp/intact" && cp -R "$BENCH"/tasks/. "$tmp/intact/"
expect 0 "every real task is valid" validates "$tmp/intact"
expect 0 "a single named task is valid" validates "$tmp/intact" "$sample"
expect 0 "the task directory is not modified" diff -r "$BENCH/tasks" "$tmp/intact"
mkdir -p "$tmp/empty"
expect 1 "an empty tasks dir exits 1" validates "$tmp/empty"

echo "• broken tasks (each must exit 1 and say why)"
# rejects <case> <reason> : validate.sh exits 1 on $tmp/<case> and its report contains <reason>,
# so a case cannot pass by failing for some unrelated reason.
rejects() {
  out="$(validates "$tmp/$1" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -Fq -- "$2"; then ok "$1: $2"
  else no "$1: wanted exit 1 and \"$2\", got exit $rc:"; printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

t="$(broken_case passes-on-seed)" && printf 'exit 0\n' >"$t/check.sh"
rejects passes-on-seed "check.sh passes on the unpatched seed"

t="$(broken_case fails-when-solved)" && printf 'exit 1\n' >"$t/check.sh"
rejects fails-when-solved "check.sh fails (exit 1) with solution.patch"

t="$(broken_case empty-patch)" && : >"$t/solution.patch"
rejects empty-patch "solution.patch does not apply"

t="$(broken_case bad-patch)" && printf -- '--- a/nope.txt\n+++ b/nope.txt\n@@ -1 +1 @@\n-a\n+b\n' \
  >"$t/solution.patch"
rejects bad-patch "solution.patch does not apply"

# `exec`, so the timeout's signal kills the sleep itself rather than orphaning it.
t="$(broken_case hangs)" && printf 'exec sleep 30\n' >"$t/check.sh"
rejects hangs "check.sh timed out (3s) on the seed"

t="$(broken_case syntax)" && printf 'if then\n' >"$t/check.sh"
rejects syntax "check.sh has a syntax error"

t="$(broken_case seed-tests-fail)" && printf 'test:\n\tfalse\n' >"$t/seed/Makefile"
rejects seed-tests-fail "make test fails on the seed"

t="$(broken_case no-seed)" && rm -rf "$t/seed"
rejects no-seed "missing seed/"

t="$(broken_case no-check)" && rm -f "$t/check.sh"
rejects no-check "missing check.sh"

# set_meta <task.md> <key> <value> : rewrite one front-matter line (portable: no `sed -i`).
set_meta() {
  awk -v k="$2" -v v="$3" 'index($0, k ":") == 1 { $0 = k ": " v } { print }' "$1" >"$1.new" \
    && mv "$1.new" "$1"
}
t="$(broken_case wrong-id)" && set_meta "$t/task.md" id something-else
rejects wrong-id "id must be \"$sample\""

t="$(broken_case bad-kind)" && set_meta "$t/task.md" kind epic
rejects bad-kind "kind must be"

t="$(broken_case bad-difficulty)" && set_meta "$t/task.md" difficulty trivial
rejects bad-difficulty "difficulty must be"

t="$(broken_case no-front-matter)" && sed '1,/^---$/d' "$t/task.md" >"$t/task.new" \
  && mv "$t/task.new" "$t/task.md"
rejects no-front-matter "line 1 must be ---"

t="$(broken_case no-title)" && sed 's/^# /Title: /' "$t/task.md" >"$t/task.new" \
  && mv "$t/task.new" "$t/task.md"
rejects no-title "must be \"# <title>\""

t="$(broken_case no-body)" && awk '{ print } /^# / { exit }' "$t/task.md" >"$t/task.new" \
  && mv "$t/task.new" "$t/task.md"
rejects no-body "empty body"

# A broken task must not hide behind valid ones.
mkdir -p "$tmp/mixed" && cp -R "$BENCH"/tasks/. "$tmp/mixed/" \
  && printf 'exit 0\n' >"$tmp/mixed/$sample/check.sh"
rejects mixed "check.sh passes on the unpatched seed"

echo
echo "selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
