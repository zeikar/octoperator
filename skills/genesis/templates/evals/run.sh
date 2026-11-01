#!/usr/bin/env bash
# run.sh — run this repo's offline scenario evals and print how many pass.
#
# Usage:
#   bash evals/run.sh [REPO_DIR]
#
# Each directory evals/<id>/ is one eval. Its scenario.md front matter says how it is judged:
#   judge: script  run `bash evals/<id>/check.sh REPO_DIR`; the eval passes only on exit 0
#   judge: model   skipped here: a model-judged eval runs only when a human dispatches it
# An eval with no scenario.md, another judge, or `judge: script` and no check.sh counts as failed,
# and so does a symlink in evals/: it is never followed.
#
# REPO_DIR defaults to the directory above this script's, and must be in a git work tree. Each
# check runs from a neutral `mktemp -d` directory, under `env -i PATH=… HOME=…`, with stdin from
# /dev/null, in its own process group, and is killed with every process it started when it exits
# or after EVALS_CHECK_TIMEOUT seconds (default 120).
#
# A check must leave REPO_DIR as it found it. When its HEAD or `git status --ignored -uall`
# differs after a check, that eval fails and the run stops there, printing `evals: aborted …`
# instead of the summary: a check that writes into the repo could make the next one pass. Under
# GitHub Actions, the run also stops before any check when evals/ differs from the commit
# (`git status -- evals`): the setup before it ran the repo's code, which could rewrite a check.
#
# It prints one line per eval, then `evals: <passed>/<total> passed (<skipped> skipped)`, where
# total counts the script evals. Under GitHub Actions (GITHUB_ACTIONS=true) it also prints
# `::notice title=evals-metric::passed=<passed> total=<total>`, and prints a failed check's output
# between `::stop-commands::<random token>` and `::<token>::`, so it cannot issue workflow
# commands.
#
# Written by /octoperator:genesis, and guarded like the evals: evals/guard.sh fails a PR that
# changes it.
#
# Exit codes: 0 every script eval passed, 1 any failed (or the run stopped), 2 bad arguments.
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
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "Not in a git work tree: $REPO (run.sh checks that no eval changes it)" >&2; exit 2; }
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

# bounded <log> <command...> : run a command from $tmp, with only PATH and HOME in its
# environment, killed after $TIMEOUT seconds (exit 142). The command gets its own process group,
# killed too once the command exits, so nothing it left running outlives it.
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
    $rc = $?;
    alarm 0;
    kill "KILL", -$pid;
    exit($rc & 127 ? 128 + ($rc & 127) : $rc >> 8);
  ' "$TIMEOUT" env -i PATH="$PATH" HOME="${HOME-}" "$@") </dev/null >"$log" 2>&1
}

# snap : prints what a check must leave alone: REPO_DIR's HEAD, and its status, ignored files too.
snap() {
  { git -C "$REPO" rev-parse -q --verify HEAD || echo "no HEAD"; } \
    && git -C "$REPO" --no-optional-locks status --porcelain --ignored -uall
}

# show_log <log> : the log's last 20 lines, indented. Under GitHub Actions they sit between
# stop-commands markers with a random token, so a line like `::notice …` is printed, not run.
show_log() {
  local tok
  if [ "${GITHUB_ACTIONS:-}" != true ]; then tail -n 20 "$1" | sed 's/^/    /'; return; fi
  tok="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  if [ "${#tok}" -ne 32 ]; then echo "    (output withheld: no random token)"; return; fi
  echo "::stop-commands::$tok"
  tail -n 20 "$1" | sed 's/^/    /'
  echo "::$tok::"
}

passed=0 failed=0 skipped=0
# failed_eval <id> <reason> [log] : count a failed eval and print why, with the log's tail.
failed_eval() {
  failed=$((failed + 1))
  echo "fail: $1 ($2)"
  [ $# -lt 3 ] || show_log "$3"
}

snap >"$tmp/before" 2>"$tmp/snap.err" \
  || { echo "run: git status failed in $REPO" >&2; cat "$tmp/snap.err" >&2; exit 2; }

# Under Actions the stack's setup ran the repo's code first (a postinstall, …), which could have
# rewritten a check, so evals/ must match the commit. Not locally, where a new eval is untracked
# while it is being written.
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  dirty="$(git -C "$REPO" --no-optional-locks status --porcelain -uall -- evals)" \
    || { echo "run: git status failed in $REPO" >&2; exit 2; }
  if [ -n "$dirty" ]; then
    echo "evals: aborted: evals/ differs from the commit before any check ran (git status)"
    printf '%s\n' "$dirty" | head -n 20 | sed 's/^/    /'
    exit 1
  fi
fi

for d in "$EVALS"/*/; do
  d="${d%/}" id="${d##*/}"
  # A link could count a check outside evals/, which the guard does not protect, or one twice.
  if [ -L "$d" ]; then failed_eval "$id" "a symlink, not an eval directory"; continue; fi
  [ -d "$d" ] || continue
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
  if ! { snap >"$tmp/after" 2>/dev/null && cmp -s "$tmp/before" "$tmp/after"; }; then
    failed_eval "$id" "changed the repo it judges" "$log"
    # The evals after it would judge a different repo, so they don't run, and no metric prints.
    echo "evals: aborted: $id changed the repo it judges (its HEAD or git status)"
    diff "$tmp/before" "$tmp/after" | head -n 20 | sed 's/^/    /'
    exit 1
  fi
  if [ "$rc" -eq 0 ]; then passed=$((passed + 1)); echo "pass: $id"
  elif [ "$rc" -eq 142 ]; then failed_eval "$id" "timed out after ${TIMEOUT}s" "$log"
  else failed_eval "$id" "exit $rc" "$log"
  fi
done

total=$((passed + failed))
echo "evals: $passed/$total passed ($skipped skipped)"
[ "${GITHUB_ACTIONS:-}" != true ] || echo "::notice title=evals-metric::passed=$passed total=$total"
[ "$failed" -eq 0 ]
