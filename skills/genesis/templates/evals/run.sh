#!/usr/bin/env bash
# run.sh — run this repo's offline scenario evals and print how many pass.
#
# Usage:
#   bash evals/run.sh [REPO_DIR]
#   bash evals/run.sh --model [REPO_DIR]
#
# Each directory evals/<id>/ is one eval. Its scenario.md front matter says how it is judged:
#   judge: script  run `bash evals/<id>/check.sh REPO_DIR`; the eval passes only on exit 0
#   judge: model   skipped, except with --model, which skips the script evals instead
# An eval with no scenario.md, another judge, or no check.sh counts as failed, and so does a
# symlink in evals/: it is never followed.
#
# --model runs each `judge: model` eval: its check.sh prints the evidence (a transcript the
# product built offline, …) and must exit 0, then evals/judge.sh asks the model whether the
# scenario.md text holds for that evidence, PASS or FAIL. Only the Evals (model) workflow runs it,
# when a human dispatches it. It needs EVALS_MAX_CALLS, a positive integer, and makes at most that
# many model calls: once they are used, each eval left fails as `call cap reached`, uncalled. The
# check runs as a script eval's does, without the model key; only judge.sh gets the key.
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
# (`git status --ignored -- evals`): the setup before it ran the repo's code, which could rewrite
# a check, or plant one that .gitignore hides.
#
# It prints one line per eval, then `evals: <passed>/<total> passed (<skipped> skipped)`, where
# total counts the script evals (the model evals with --model, which also prints
# `evals: model calls: <calls>/<EVALS_MAX_CALLS>`). Under GitHub Actions (GITHUB_ACTIONS=true) it
# also prints `::notice title=evals-metric::passed=<passed> total=<total>`, without --model, and
# prints a failed check's output
# between `::stop-commands::<random token>` and `::<token>::`, so it cannot issue workflow
# commands.
#
# Written by /octoperator:genesis, and guarded like the evals: evals/guard.sh fails a PR that
# changes it.
#
# Exit codes: 0 every eval it ran passed, 1 any failed (or the run stopped), 2 bad arguments (or,
# with --model, no EVALS_MAX_CALLS or model key).
set -uo pipefail

RUN=script SKIP=model
case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  --model) RUN=model SKIP=script; shift ;;
esac
case "${1:-}" in -*) echo "Unknown argument: $1" >&2; exit 2 ;; esac
[ $# -le 1 ] || { echo "Usage: bash evals/run.sh [--model] [REPO_DIR]" >&2; exit 2; }

EVALS="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-$EVALS/..}"
[ -d "$REPO" ] || { echo "Not a directory: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "Not in a git work tree: $REPO (run.sh checks that no eval changes it)" >&2; exit 2; }
TIMEOUT="${EVALS_CHECK_TIMEOUT:-120}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=0 ;; esac
[ "$TIMEOUT" -ge 1 ] || { echo "EVALS_CHECK_TIMEOUT must be a positive integer" >&2; exit 2; }
if [ "$RUN" = model ]; then
  # Every model call spends money: no cap, no run.
  MAX_CALLS="${EVALS_MAX_CALLS:-}"
  case "$MAX_CALLS" in ''|*[!0-9]*) MAX_CALLS=0 ;; esac
  [ "$MAX_CALLS" -ge 1 ] || { echo "EVALS_MAX_CALLS must be a positive integer" >&2; exit 2; }
  [ -n "${ANTHROPIC_API_KEY:-}" ] \
    || { echo "ANTHROPIC_API_KEY is not set: add it as a repo secret" >&2; exit 2; }
  [ -f "$EVALS/judge.sh" ] || { echo "No $EVALS/judge.sh" >&2; exit 2; }
fi

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "run: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# judge <scenario.md> : prints the front matter's judge value, unquoted, or nothing.
judge() {
  awk -v sq="'" 'NR == 1 { if ($0 != "---") exit; next }
       $0 == "---" { exit }
       index($0, "judge:") == 1 { v = substr($0, 7); gsub(/^[ \t]+|[ \t\r]+$/, "", v)
         gsub("^[\"" sq "]|[\"" sq "]$", "", v); print v; exit }' "$1"
}

# bounded <command...> : run a command from $tmp, with only PATH and HOME in its environment,
# killed after $TIMEOUT seconds (exit 142). The command gets its own process group, killed too
# once the command exits, so nothing it left running outlives it.
bounded() {
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
  ' "$TIMEOUT" env -i PATH="$PATH" HOME="${HOME-}" "$@")
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

passed=0 failed=0 skipped=0 calls=0
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
  dirty="$(git -C "$REPO" --no-optional-locks status --porcelain --ignored -uall -- evals)" \
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
    "$SKIP") skipped=$((skipped + 1)); echo "skip: $id (judge: $j)"; continue ;;
    "$RUN") ;;
    *) failed_eval "$id" "judge must be script or model, got '$j'"; continue ;;
  esac
  if [ ! -f "$d/check.sh" ]; then failed_eval "$id" "no check.sh"; continue; fi
  log="$tmp/$id.log"
  # A model eval's check prints the evidence on stdout, kept apart from its log.
  if [ "$RUN" = model ]; then
    bounded bash "$d/check.sh" "$REPO" </dev/null >"$tmp/$id.out" 2>"$log"
  else
    bounded bash "$d/check.sh" "$REPO" </dev/null >"$log" 2>&1
  fi
  rc=$?
  if ! { snap >"$tmp/after" 2>/dev/null && cmp -s "$tmp/before" "$tmp/after"; }; then
    failed_eval "$id" "changed the repo it judges" "$log"
    # The evals after it would judge a different repo, so they don't run, and no metric prints.
    echo "evals: aborted: $id changed the repo it judges (its HEAD or git status)"
    diff "$tmp/before" "$tmp/after" | head -n 20 | sed 's/^/    /'
    exit 1
  fi
  if [ "$rc" -eq 142 ]; then failed_eval "$id" "timed out after ${TIMEOUT}s" "$log"; continue; fi
  if [ "$rc" -ne 0 ]; then failed_eval "$id" "exit $rc" "$log"; continue; fi
  if [ "$RUN" = script ]; then passed=$((passed + 1)); echo "pass: $id"; continue; fi
  if [ ! -s "$tmp/$id.out" ]; then failed_eval "$id" "check.sh printed no evidence" "$log"; continue
  fi
  if [ "$calls" -ge "$MAX_CALLS" ]; then
    failed_eval "$id" "call cap reached: EVALS_MAX_CALLS=$MAX_CALLS"; continue
  fi
  calls=$((calls + 1))
  { echo "Scenario:"
    awk 'NR == 1 { next } !body && $0 == "---" { body = 1; next } body' "$d/scenario.md"
    printf '\nEvidence:\n'
    cat "$tmp/$id.out"
  } >"$tmp/$id.prompt"
  # judge.sh prints one line; control characters out, so it can't start a workflow command.
  verdict="$(bash "$EVALS/judge.sh" "$tmp/$id.prompt" </dev/null 2>"$log" | head -n 1 \
    | tr -d '\000-\037\177')"
  if [ "$verdict" = PASS ]; then passed=$((passed + 1)); echo "pass: $id"
  else failed_eval "$id" "judge: ${verdict:-no answer}" "$log"
  fi
done

total=$((passed + failed))
echo "evals: $passed/$total passed ($skipped skipped)"
[ "$RUN" = script ] || echo "evals: model calls: $calls/$MAX_CALLS"
[ "$RUN" = model ] || [ "${GITHUB_ACTIONS:-}" != true ] \
  || echo "::notice title=evals-metric::passed=$passed total=$total"
[ "$failed" -eq 0 ]
