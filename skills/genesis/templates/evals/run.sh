#!/usr/bin/env bash
# run.sh — run this repo's offline scenario evals and print how many pass.
#
# Usage:
#   bash evals/run.sh [REPO_DIR]
#
# Each directory evals/<id>/ is one eval. Its scenario.md front matter says how it is judged:
#   judge: script  run `bash evals/<id>/check.sh REPO_DIR`; the eval passes only on exit 0
#   judge: model   skipped here: a model-judged eval runs only when a human dispatches it
# An eval with no scenario.md, another judge, or `judge: script` and no check.sh counts as failed.
#
# REPO_DIR defaults to the directory above this script's. Each check runs from a neutral
# `mktemp -d` directory with stdin from /dev/null, in its own process group, and is killed with
# every process it started after EVALS_CHECK_TIMEOUT seconds (default 120).
#
# It prints one line per eval, then `evals: <passed>/<total> passed (<skipped> skipped)`, where
# total counts the script evals. Under GitHub Actions (GITHUB_ACTIONS=true) it also prints
# `::notice title=evals-metric::passed=<passed> total=<total>`.
#
# Written by /octoperator:genesis, and guarded like the evals: evals/guard.sh fails a PR that
# changes it.
#
# Exit codes: 0 every script eval passed, 1 any failed, 2 bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  -*) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "Usage: bash evals/run.sh [REPO_DIR]" >&2; exit 2; }

EVALS="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-$EVALS/..}"
[ -d "$REPO" ] || { echo "Not a directory: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
TIMEOUT="${EVALS_CHECK_TIMEOUT:-120}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=0 ;; esac
[ "$TIMEOUT" -ge 1 ] || { echo "EVALS_CHECK_TIMEOUT must be a positive integer" >&2; exit 2; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "run: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# judge <scenario.md> : prints the front matter's judge value, unquoted, or nothing.
judge() {
  awk -v sq="'" 'NR == 1 { if ($0 != "---") exit; next }
       $0 == "---" { exit }
       index($0, "judge:") == 1 { v = substr($0, 7); gsub(/^[ \t]+|[ \t\r]+$/, "", v)
         gsub("^[\"" sq "]|[\"" sq "]$", "", v); print v; exit }' "$1"
}

# bounded <log> <command...> : run a command from $tmp, killed after $TIMEOUT seconds (exit 142).
# The command gets its own process group, so a timeout kills everything it started.
bounded() {
  local log="$1"; shift
  (cd "$tmp" && perl -e '
    $t = shift;
    defined($pid = fork) or die "fork: $!\n";
    if (!$pid) { setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!\n"; }
    setpgrp($pid, $pid);
    $SIG{ALRM} = sub { kill "KILL", -$pid; exit 142 };
    $SIG{$_} = sub { kill "KILL", -$pid; $SIG{$_[0]} = "DEFAULT"; kill $_[0], $$ }
      for qw(INT TERM HUP);
    alarm $t;
    waitpid($pid, 0);
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$TIMEOUT" "$@") </dev/null >"$log" 2>&1
}

passed=0 failed=0 skipped=0
# failed_eval <id> <reason> [log] : count a failed eval and print why, with the log's tail.
failed_eval() {
  failed=$((failed + 1))
  echo "fail: $1 ($2)"
  [ $# -lt 3 ] || tail -n 20 "$3" | sed 's/^/    /'
}

for d in "$EVALS"/*/; do
  [ -d "$d" ] || continue
  d="${d%/}" id="${d##*/}"
  if [ ! -f "$d/scenario.md" ]; then failed_eval "$id" "no scenario.md"; continue; fi
  j="$(judge "$d/scenario.md")"
  case "$j" in
    model) skipped=$((skipped + 1)); echo "skip: $id (judge: model)"; continue ;;
    script) ;;
    *) failed_eval "$id" "judge must be script or model, got '$j'"; continue ;;
  esac
  if [ ! -f "$d/check.sh" ]; then failed_eval "$id" "no check.sh"; continue; fi
  log="$tmp/$id.log"
  bounded "$log" bash "$d/check.sh" "$REPO"
  rc=$?
  if [ "$rc" -eq 0 ]; then passed=$((passed + 1)); echo "pass: $id"
  elif [ "$rc" -eq 142 ]; then failed_eval "$id" "timed out after ${TIMEOUT}s" "$log"
  else failed_eval "$id" "exit $rc" "$log"
  fi
done

total=$((passed + failed))
echo "evals: $passed/$total passed ($skipped skipped)"
[ "${GITHUB_ACTIONS:-}" != true ] || echo "::notice title=evals-metric::passed=$passed total=$total"
[ "$failed" -eq 0 ]
