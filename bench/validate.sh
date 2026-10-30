#!/usr/bin/env bash
# validate.sh — offline check that every benchmark task is well-formed and its oracle is sound.
#
# Usage:
#   bench/validate.sh [--tasks DIR] [TASK_ID ...]
#
# Validates every task under DIR (default: the tasks/ directory next to this script), or only the
# named TASK_IDs. A task is valid when:
#   - it has task.md, seed/, check.sh, and solution.patch
#   - task.md parses: front matter with id (equal to the directory name), kind, and difficulty,
#     then a `# <title>` line and a non-empty body (format: bench/README.md)
#   - on a fresh copy of seed/, `make test` passes and check.sh fails
#   - solution.patch applies cleanly (`git apply`) to another fresh copy, and both `make test` and
#     check.sh pass there
#
# Each copy is a throwaway `git init` repo under one `mktemp -d` directory; the task directory is
# never modified. Each `make test` and check.sh run is killed, with every process it started,
# after BENCH_CHECK_TIMEOUT seconds (default 120). Nothing here calls claude, gh, or the
# network. Exits 0 when every task is valid, 1 when any task is broken or no task was found, 2 on
# bad arguments.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TASKS_DIR="$HERE/tasks"
TIMEOUT="${BENCH_CHECK_TIMEOUT:-120}"
ids=()

need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --tasks) need_value "$@"; TASKS_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) ids+=("$1"); shift ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*) TIMEOUT=0 ;;
esac
[ "$TIMEOUT" -ge 1 ] || { echo "BENCH_CHECK_TIMEOUT must be a positive integer" >&2; exit 2; }
[ -d "$TASKS_DIR" ] || { echo "No such tasks directory: $TASKS_DIR" >&2; exit 2; }
TASKS_DIR="$(cd "$TASKS_DIR" && pwd)"

task_dirs=()
if [ "${#ids[@]}" -gt 0 ]; then
  for id in "${ids[@]}"; do
    [ -d "$TASKS_DIR/$id" ] || { echo "No such task: $id (in $TASKS_DIR)" >&2; exit 2; }
    task_dirs+=("$TASKS_DIR/$id")
  done
else
  for d in "$TASKS_DIR"/*/; do
    [ -d "$d" ] && task_dirs+=("${d%/}")
  done
fi
if [ "${#task_dirs[@]}" -eq 0 ]; then
  echo "validate: no tasks found in $TASKS_DIR" >&2
  exit 1
fi

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "validate: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# task_md_problems <task.md> <id> : prints one line per format problem; nothing when valid.
task_md_problems() {
  awk -v want="$2" '
    function bad(msg) { print msg; nbad++ }
    NR == 1 && $0 != "---" { bad("task.md: line 1 must be ---"); state = "dead"; exit }
    NR == 1 { state = "meta"; next }
    state == "meta" && $0 == "---" { state = "title"; next }
    state == "meta" {
      if (match($0, /^[a-z_]+:[ \t]*/)) {
        key = substr($0, 1, index($0, ":") - 1)
        val = substr($0, RLENGTH + 1); sub(/[ \t]+$/, "", val)
        meta[key] = val
      } else bad("task.md: bad front matter line " NR ": " $0)
      next
    }
    state == "title" && /^[ \t]*$/ { next }
    state == "title" {
      if ($0 ~ /^# [^ \t]/) title = 1
      else bad("task.md: first line after the front matter must be \"# <title>\"")
      state = "body"; next
    }
    state == "body" && $0 !~ /^[ \t]*$/ { body = 1 }
    END {
      if (state == "dead") exit
      if (NR == 0) { bad("task.md: empty"); exit }
      if (state == "meta") { bad("task.md: front matter is not closed with ---"); exit }
      if (meta["id"] != want) bad("task.md: id must be \"" want "\", got \"" meta["id"] "\"")
      if (meta["kind"] !~ /^(feature|bug|chore|docs)$/)
        bad("task.md: kind must be feature, bug, chore, or docs, got \"" meta["kind"] "\"")
      if (meta["difficulty"] !~ /^(easy|medium|hard)$/)
        bad("task.md: difficulty must be easy, medium, or hard, got \"" meta["difficulty"] "\"")
      if (state == "title") bad("task.md: no \"# <title>\" line")
      else if (title && !body) bad("task.md: empty body")
    }' "$1"
}

# fresh_copy <task-dir> <dest> : copy seed/ into a new `git init` repo at <dest>.
fresh_copy() {
  mkdir -p "$2" && cp -R "$1/seed/." "$2/" && git -c init.defaultBranch=main init -q "$2"
}

# bounded <cwd> <log> <command...> : run a command in <cwd>, killed after $TIMEOUT seconds (macOS
# has no `timeout`; a kill exits 142). The command runs in its own process group, and a timeout
# kills the whole group, so nothing it started outlives it. Its stdin is /dev/null: it is not the
# terminal's foreground group, so reading the terminal would stop it. check.sh runs from the
# neutral $tmp, so it cannot lean on the working directory.
bounded() {
  cwd="$1"; log="$2"; shift 2
  (cd "$cwd" && perl -e '
    $t = shift;
    defined($pid = fork) or die "fork: $!\n";
    if (!$pid) { setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!\n"; }
    setpgrp($pid, $pid);  # also here, so the kill below cannot race the child
    $SIG{ALRM} = sub { kill "KILL", -$pid; exit 142 };
    alarm $t;
    waitpid($pid, 0);
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$TIMEOUT" "$@") </dev/null >"$log" 2>&1
}

# problem <message> [log] : record a problem with the current task, plus the tail of a log.
problem() {
  broken=1
  echo "    - $1"
  [ $# -lt 2 ] || tail -n 15 "$2" | sed 's/^/        /'
}

# validate_task <task-dir> : prints the task's verdict and its problems; sets `broken`.
validate_task() {
  dir="$1"; id="$(basename "$dir")"; broken=0
  work="$tmp/$id"
  report="$tmp/$id.report"
  {
    for f in task.md check.sh solution.patch; do
      [ -f "$dir/$f" ] || problem "missing $f"
    done
    [ -d "$dir/seed" ] || problem "missing seed/"
    if [ "$broken" -eq 0 ]; then
      task_md_problems "$dir/task.md" "$id" >"$work.md" 2>&1
      [ -s "$work.md" ] && while IFS= read -r line; do problem "$line"; done <"$work.md"
      bash -n "$dir/check.sh" 2>"$work.syntax" \
        || problem "check.sh has a syntax error" "$work.syntax"
    fi
    if [ "$broken" -eq 0 ]; then
      if ! fresh_copy "$dir" "$work/seed" >"$work.copy" 2>&1; then
        problem "could not copy seed/" "$work.copy"
      else
        bounded "$work/seed" "$work.test.log" make test
        rc=$?
        if [ "$rc" -eq 142 ]; then problem "make test timed out (${TIMEOUT}s) on the seed"
        elif [ "$rc" -ne 0 ]; then problem "make test fails on the seed" "$work.test.log"
        fi
        bounded "$tmp" "$work.seed.log" bash "$dir/check.sh" "$work/seed"
        rc=$?
        if [ "$rc" -eq 0 ]; then problem "check.sh passes on the unpatched seed" "$work.seed.log"
        elif [ "$rc" -eq 142 ]; then problem "check.sh timed out (${TIMEOUT}s) on the seed"
        fi
      fi
      if ! fresh_copy "$dir" "$work/solved" >"$work.copy" 2>&1; then
        problem "could not copy seed/" "$work.copy"
      elif ! git -C "$work/solved" apply --whitespace=nowarn "$dir/solution.patch" \
             >"$work.apply" 2>&1; then
        problem "solution.patch does not apply to the seed" "$work.apply"
      else
        # check.sh should run `make test` itself, but don't rely on it.
        bounded "$work/solved" "$work.solved-test.log" make test
        rc=$?
        if [ "$rc" -eq 142 ]; then problem "make test timed out (${TIMEOUT}s) with solution.patch"
        elif [ "$rc" -ne 0 ]; then
          problem "make test fails with solution.patch" "$work.solved-test.log"
        fi
        bounded "$tmp" "$work.solved.log" bash "$dir/check.sh" "$work/solved"
        rc=$?
        if [ "$rc" -eq 142 ]; then problem "check.sh timed out (${TIMEOUT}s) with solution.patch"
        elif [ "$rc" -ne 0 ]; then
          problem "check.sh fails (exit $rc) with solution.patch" "$work.solved.log"
        fi
      fi
    fi
  } >"$report"
  if [ "$broken" -eq 0 ]; then echo "  ✓ $id"; else echo "  ✗ $id"; cat "$report"; fi
}

valid=0
invalid=0
echo "• bench tasks ($TASKS_DIR)"
for dir in "${task_dirs[@]}"; do
  validate_task "$dir"
  if [ "$broken" -eq 0 ]; then valid=$((valid + 1)); else invalid=$((invalid + 1)); fi
done

echo
echo "validate: $valid valid, $invalid broken"
[ "$invalid" -eq 0 ]
