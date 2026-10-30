#!/usr/bin/env bash
# selftest.sh — prove bench/validate.sh catches broken benchmark tasks.
#
# Usage:
#   bench/test/selftest.sh
#
# Copies the real tasks into a `mktemp -d` directory, breaks one copy per case (a check that
# always passes or always fails, a patch that does not apply, a malformed task.md, a missing
# seed/, failing seed tests, a reference fix that breaks the tests, a check that hangs), and
# asserts validate.sh exits 1 for each, with the expected reason, and 0 for the intact copy, and
# that Ctrl-C on validate.sh also stops a running check.
# Also covers its argument handling (--help, unknown argument, missing value, unknown task), and
# that the real oracles reject plausible wrong fixes while accepting other correct ones.
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

# The check leaves a child running: the timeout must kill it too, not orphan it.
t="$(broken_case hangs)" && printf 'sleep 30 &\necho $! >>"%s"\nwait\n' "$tmp/hang.pids" \
  >"$t/check.sh"
rejects hangs "check.sh timed out (3s) on the seed"
# alive : print the recorded pids that are still running.
alive() { while read -r pid; do kill -0 "$pid" 2>/dev/null && echo "$pid"; done <"$tmp/hang.pids"; }
left="$(alive)"
[ -z "$left" ] || { sleep 1; left="$(alive)"; }  # give a killed child a moment to be reaped
if [ ! -s "$tmp/hang.pids" ]; then no "hangs: the check recorded no child pid"
elif [ -z "$left" ]; then ok "hangs: the timeout kills what check.sh started"
else no "hangs: left running: $(printf '%s' "$left" | tr '\n' ' ')"; alive | xargs kill 2>/dev/null
fi

# Ctrl-C on validate.sh must kill a running check too: interrupt validate.sh's process group (its
# own, via job control) while the check runs.
t="$(broken_case interrupted)" && printf 'echo $$ >"%s"\nexec sleep 30\n' "$tmp/int.pid" \
  >"$t/check.sh"
vpid="$(set -m; bash "$VALIDATE" --tasks "$tmp/interrupted" >/dev/null 2>&1 & echo $!)"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/int.pid" ] && break; sleep 1; done
cpid="$(cat "$tmp/int.pid" 2>/dev/null)"
kill -INT -- "-$vpid" 2>/dev/null
for _ in 1 2 3 4 5; do kill -0 "$cpid" 2>/dev/null || kill -0 "$vpid" 2>/dev/null || break; sleep 1
done
if [ -z "$cpid" ]; then no "interrupted: the check never started"
elif kill -0 "$cpid" 2>/dev/null; then no "interrupted: the check outlived Ctrl-C"; kill "$cpid"
elif kill -0 "$vpid" 2>/dev/null; then no "interrupted: validate.sh outlived Ctrl-C"; kill "$vpid"
else ok "interrupted: Ctrl-C stops validate.sh and the check"
fi

t="$(broken_case syntax)" && printf 'if then\n' >"$t/check.sh"
rejects syntax "check.sh has a syntax error"

t="$(broken_case seed-tests-fail)" && printf 'test:\n\tfalse\n' >"$t/seed/Makefile"
rejects seed-tests-fail "make test fails on the seed"

# The reference fix breaks the repo's tests, and check.sh does not run them.
# shellcheck disable=SC2016  # $1 belongs to the written check.sh, not to this script
t="$(broken_case solved-tests-fail)" && printf 'test:\n\t[ ! -f SOLVED ]\n' >"$t/seed/Makefile" \
  && printf '[ -f "$1/SOLVED" ]\n' >"$t/check.sh" \
  && printf '%s\n' 'diff --git a/SOLVED b/SOLVED' 'new file mode 100644' '--- /dev/null' \
    '+++ b/SOLVED' '@@ -0,0 +1 @@' '+x' >"$t/solution.patch"
rejects solved-tests-fail "make test fails with solution.patch"

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

echo "• oracles judge alternative fixes (wrong ones fail, other correct ones pass)"
# judges <wanted-exit> <label> <task> <repo> : the task's check.sh exits <wanted-exit> on <repo>.
judges() { expect "$1" "$3: $2" bash "$BENCH/tasks/$3/check.sh" "$4"; }
# variant <task> <name> : a fresh copy of <task>'s seed at $tmp/oracle/<name>; prints its path.
variant() {
  mkdir -p "$tmp/oracle/$2" && cp -R "$BENCH/tasks/$1/seed/." "$tmp/oracle/$2/" \
    && echo "$tmp/oracle/$2"
}
# vsort_with <name> <expr> : a vsort-numeric seed whose version_key returns <expr>.
vsort_with() {
  d="$(variant vsort-numeric "$1")" \
    && sed "s/return version.strip().split(\".\")/return $2/" \
      "$BENCH/tasks/vsort-numeric/seed/vsort.py" >"$d/vsort.py" \
    && grep -Fq "return $2" "$d/vsort.py" && echo "$d"
}
judges 0 "a list-of-int key" vsort-numeric \
  "$(vsort_with list-key '[int(p) for p in version.split(".")]')"
judges 1 "a (length, text) key" vsort-numeric "$(vsort_with len-key '(len(version), version)')"
judges 1 "a digits-only key" vsort-numeric \
  "$(vsort_with digits-key 'int(version.replace(".", ""))')"

# retry_doc <name> <config rows> <exit status table> : a retry-docs seed whose README.md gains a
# Configuration section with <config rows> under a Variable | Default | Description header, and
# an Exit status section holding <exit status table>.
nl=$'\n'
retry_doc() {
  d="$(variant retry-docs "$1")" && printf '\n%s\n' "## Configuration$nl$nl| Variable | Default \
| Description |$nl|---|---|---|$nl$2$nl$nl## Exit status$nl$nl$3" >>"$d/README.md" && echo "$d"
}
# statuses <success row> <fail row> <usage row> : a Case | Exit status table with these rows.
statuses() { printf '| Case | Exit status |\n|---|---|\n%s\n%s\n%s' "$1" "$2" "$3"; }
rows="| \`RETRY_ATTEMPTS\` | \`5\` | Maximum attempts |$nl| \`RETRY_DELAY\` | \`2\` | Pause |"
ok_row="| Success | \`0\` |"
usage_row="| Called without a command | \`2\` |"
last_row="| Every attempt fails | The exit status of the last attempt |"
table="$(statuses "$ok_row" "$last_row" "$usage_row")"
# retry_judges <wanted-exit> <label> <config rows> <exit status table>
n=0
retry_judges() {
  n=$((n + 1)); judges "$1" "$2" retry-docs "$(retry_doc "case$n" "$3" "$4")"
}
retry_judges 0 "bare cells, no outer pipes, rows swapped, \"2 seconds\"" \
  "RETRY_DELAY | 2 seconds | Pause${nl}RETRY_ATTEMPTS | 5 | Maximum attempts" "$table"
retry_judges 0 "\"2s\" for the delay, \"5 attempts\"" \
  "| RETRY_ATTEMPTS | 5 attempts | Maximum attempts |$nl| RETRY_DELAY | \`2s\` | Pause |" "$table"
retry_judges 0 "\$-prefixed variables" \
  "| \`\$RETRY_ATTEMPTS\` | 5 | Maximum attempts |$nl| \`\$RETRY_DELAY\` | 2 | Pause |" "$table"
retry_judges 0 "exit status rows reordered, no outer pipes" "$rows" \
  "Case | Exit status$nl---|---${nl}No command given | 2 (usage error)${nl}\
All attempts fail | last attempt's exit code${nl}An attempt succeeds | exits 0"
for fail_row in \
  "| Every attempt fails | Status of the most recent attempt |" \
  "| Attempts run out | Passes through the command's status |" \
  "| No attempt succeeds | The final attempt's exit status |"
do retry_judges 0 "fail row \"$fail_row\"" "$rows" \
  "$(statuses "$ok_row" "$fail_row" "$usage_row")"; done
for fail_row in \
  "| Every attempt fails | \`1\` |" \
  "| Every attempt fails | non-zero |" \
  "| Every attempt fails | 1 (the last attempt failed) |" \
  "| Every attempt fails | The command's exit status |"
do retry_judges 1 "fail row \"$fail_row\"" "$rows" \
  "$(statuses "$ok_row" "$fail_row" "$usage_row")"; done
retry_judges 1 "no fail row" "$rows" "$(statuses "$ok_row" "$usage_row" "")"
retry_judges 1 "no usage row" "$rows" "$(statuses "$ok_row" "$last_row" "")"
retry_judges 1 "success gives 1" "$rows" \
  "$(statuses "| Success | 1 |" "$last_row" "$usage_row")"
retry_judges 1 "usage gives 1" "$rows" \
  "$(statuses "$ok_row" "$last_row" "| Called without a command | 1 |")"
retry_judges 1 "prose instead of the table" "$rows" \
  "retry.sh exits with the exit status of the last attempt."
retry_judges 1 "wrong defaults in the table" \
  "| RETRY_ATTEMPTS | 3 | Maximum attempts |$nl| RETRY_DELAY | 1 | Pause |" "$table"
retry_judges 1 "defaults swapped between the rows" \
  "| RETRY_ATTEMPTS | 2 | Maximum attempts |$nl| RETRY_DELAY | 5 | Pause |" "$table"
retry_judges 1 "a row missing" "| RETRY_ATTEMPTS | 5 | Maximum attempts |" "$table"
retry_judges 1 "an empty description" \
  "| RETRY_ATTEMPTS | 5 | Maximum attempts |$nl| RETRY_DELAY | 2 | |" "$table"
d="$(variant retry-docs no-table)" && printf '\n%s\n' "## Configuration$nl$nl- RETRY_ATTEMPTS: \
default 5$nl- RETRY_DELAY: default 2$nl$nl## Exit status$nl$nl$table" >>"$d/README.md"
judges 1 "a list instead of the table" retry-docs "$d"

echo
echo "selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
