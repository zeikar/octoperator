#!/usr/bin/env bash
# octo-bench.sh — opt-in harness: run /octoperator:auto on the bench/ tasks and record outcomes.
#
# Usage:
#   octo-bench.sh setup <task> --run-id <id> [--owner <o>]          --live | --dry-run
#   octo-bench.sh solve <owner/repo> <issue#> [--plugin-dir <dir>]  --live | --dry-run
#   octo-bench.sh check <task> <owner/repo>                         --live | --dry-run
#   octo-bench.sh cleanup --run-id <id> [--owner <o>]               --live | --dry-run
#   octo-bench.sh run --tasks <a,b|all> --run-id <id> [--owner <o>] [--plugin-dir <dir>]
#                     [--max-cost-usd N]                            --live | --dry-run
#
#   setup    Create the private repo <owner>/octo-bench-<task>-<id> (owner: the gh user) from the
#            task's seed/ plus a .claude/settings.json allowing gh, git, make test, and the file
#            tools. File the issue from task.md, and print "<owner/repo> <issue#>".
#   solve    Optional. Clone the bench repo (owner/octo-bench-<task>-<id>; no other repo) and
#            run `claude -p "/octoperator:auto <issue#>"` in it, with the plugin loaded from
#            --plugin-dir (default: this checkout), for at most BENCH_SOLVE_TIMEOUT seconds
#            (default 3600). Saves the JSON to <results>/<repo-name>.solve.json. Instead, the
#            session's own agent may run /octoperator:auto in a clone.
#   check    Clone the default branch, run the task's hidden check.sh on it from bench/tasks/<task>/
#            (never copied into the repo; at most BENCH_CHECK_TIMEOUT seconds, default 120). Then
#            read the PR's metrics through gh and append one JSON line to <results>/<id>.jsonl.
#   cleanup  Delete this run's repos. Without the delete_repo scope, list them instead.
#   run      setup, solve, then check for each task. Once the total cost passes --max-cost-usd, it
#            starts no more tasks; with the cap set, it also stops after a solve whose cost is
#            unknown (claude ran but reported none, e.g. it timed out).
#
# Every subcommand creates or reads real GitHub repos, so it runs only with --live. Without
# --live (or --dry-run) it exits 2 before any gh or claude call. --dry-run prints the planned
# repos, issues, and commands and touches nothing. <results> is BENCH_RESULTS_DIR (default
# bench/results). Costs real money and API quota: never run it in CI.
# Exits 0 on success, 1 on failure, 2 on bad arguments or a missing --live.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASKS="$ROOT/bench/tasks"
RESULTS="${BENCH_RESULTS_DIR:-$ROOT/bench/results}"
SOLVE_TIMEOUT="${BENCH_SOLVE_TIMEOUT:-3600}"
CHECK_TIMEOUT="${BENCH_CHECK_TIMEOUT:-120}"

warn() { echo "octo-bench: $*" >&2; }
die() { warn "$*"; exit 1; }
usage_err() { warn "$*"; echo "Run octo-bench.sh --help for usage." >&2; exit 2; }
need_value() { [ $# -ge 2 ] || usage_err "missing value for $1"; }

SUB="" P1="" P2="" LIVE=0 DRY=0 RUN_ID="" OWNER="" PLUGIN_DIR="$ROOT" TASK_LIST="" MAX_COST=""
flags=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    --live) LIVE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --run-id) need_value "$@"; RUN_ID="$2"; flags="$flags $1"; shift 2 ;;
    --owner) need_value "$@"; OWNER="$2"; flags="$flags $1"; shift 2 ;;
    --plugin-dir) need_value "$@"; PLUGIN_DIR="$2"; flags="$flags $1"; shift 2 ;;
    --tasks) need_value "$@"; TASK_LIST="$2"; flags="$flags $1"; shift 2 ;;
    --max-cost-usd) need_value "$@"; MAX_COST="$2"; flags="$flags $1"; shift 2 ;;
    -*) usage_err "unknown argument: $1" ;;
    *)
      if [ -z "$SUB" ]; then SUB="$1"
      elif [ -z "$P1" ]; then P1="$1"
      elif [ -z "$P2" ]; then P2="$1"
      else usage_err "unexpected argument: $1"
      fi
      shift ;;
  esac
done

# allow <flags...> : reject any flag given that this subcommand does not take.
allow() {
  for f in $flags; do
    case " $* " in *" $f "*) ;; *) usage_err "$f does not apply to $SUB" ;; esac
  done
}
# positionals <count> : this subcommand takes exactly <count> positional arguments.
positionals() {
  got=0
  [ -z "$P1" ] || got=1
  [ -z "$P2" ] || got=2
  [ "$got" -eq "$1" ] || usage_err "$SUB takes $1 positional argument(s), got $got"
}
valid_task() {
  case "$1" in ''|*[!a-z0-9-]*) usage_err "bad task id: $1" ;; esac
  [ -f "$TASKS/$1/task.md" ] || usage_err "no such task: $1 (in $TASKS)"
}
valid_repo() {
  case "$1" in */*/*|/*|*/|*[!A-Za-z0-9._/-]*) usage_err "bad repo (want owner/name): $1" ;; esac
  case "$1" in */*) ;; *) usage_err "bad repo (want owner/name): $1" ;; esac
}
need_run_id() {
  case "$RUN_ID" in
    '') usage_err "$SUB needs --run-id" ;;
    -*|*[!A-Za-z0-9._-]*) usage_err "bad --run-id (letters, digits, . _ - only): $RUN_ID" ;;
  esac
}

case "$SUB" in
  setup) allow --run-id --owner; positionals 1; valid_task "$P1"; need_run_id ;;
  solve)
    allow --plugin-dir; positionals 2; valid_repo "$P1"
    case "$P2" in *[!0-9]*) usage_err "bad issue number: $P2" ;; esac
    # solve runs unattended `auto` (implement and merge): never aim it at a non-bench repo.
    bench_repo=0
    for d in "$TASKS"/*/; do
      case "${P1#*/}" in "octo-bench-$(basename "$d")-"?*) bench_repo=1 ;; esac
    done
    [ "$bench_repo" -eq 1 ] \
      || usage_err "$P1 is not a bench repo (want owner/octo-bench-<task>-<run-id>)" ;;
  check)
    allow; positionals 2; valid_task "$P1"; valid_repo "$P2"
    # The run id lives in the repo name; check needs it to find the results file.
    prefix="octo-bench-$P1-"
    case "${P2#*/}" in
      "$prefix"?*) CHECK_RUN_ID="${P2#*/"$prefix"}" ;;
      *) usage_err "$P2 is not a $P1 bench repo (want owner/$prefix<run-id>)" ;;
    esac ;;
  cleanup) allow --run-id --owner; positionals 0; need_run_id ;;
  run)
    allow --tasks --run-id --owner --plugin-dir --max-cost-usd; positionals 0; need_run_id
    [ -n "$TASK_LIST" ] || usage_err "run needs --tasks <a,b|all>"
    if [ "$TASK_LIST" = all ]; then
      TASK_LIST=""
      for d in "$TASKS"/*/; do [ -f "$d/task.md" ] && TASK_LIST="$TASK_LIST $(basename "$d")"; done
    else
      TASK_LIST="$(printf '%s' "$TASK_LIST" | tr ',' ' ')"
    fi
    for t in $TASK_LIST; do valid_task "$t"; done
    [ -n "${TASK_LIST// /}" ] || usage_err "no tasks to run"
    if [ -n "$MAX_COST" ]; then
      printf '%s' "$MAX_COST" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
        || usage_err "bad --max-cost-usd: $MAX_COST"
    fi ;;
  '') usage_err "missing subcommand (setup, solve, check, cleanup, or run)" ;;
  *) usage_err "unknown subcommand: $SUB" ;;
esac
case "$OWNER" in *[!A-Za-z0-9-]*) usage_err "bad --owner: $OWNER" ;; esac
[ -d "$PLUGIN_DIR" ] || usage_err "no such --plugin-dir: $PLUGIN_DIR"
PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"
for v in "$SOLVE_TIMEOUT" "$CHECK_TIMEOUT"; do
  case "$v" in ''|*[!0-9]*|0) usage_err "BENCH_*_TIMEOUT must be a positive integer" ;; esac
done

if [ "$DRY" -eq 0 ] && [ "$LIVE" -eq 0 ]; then
  warn "$SUB creates or reads real GitHub repos (and solve runs claude): pass --live to run it,"
  warn "or --dry-run to print the plan"
  exit 2
fi

# task_part <task.md> <kind|title|body> : one part of a task.md (format: bench/README.md).
task_part() {
  awk -v want="$2" '
    NR == 1 { next }
    state == "" && $0 == "---" { state = "title"; next }
    state == "" && index($0, "kind:") == 1 { kind = $0; sub(/^kind:[ \t]*/, "", kind) }
    state == "" { next }
    state == "title" && /^[ \t]*$/ { next }
    state == "title" { title = substr($0, 3); state = "body"; next }
    { lines[++n] = $0 }
    END {
      if (want == "kind") { sub(/[ \t]+$/, "", kind); print kind; exit }
      if (want == "title") { print title; exit }
      s = 1; while (s <= n && lines[s] ~ /^[ \t]*$/) s++
      e = n; while (e >= s && lines[e] ~ /^[ \t]*$/) e--
      for (i = s; i <= e; i++) print lines[i]
    }' "$1"
}

# bounded <seconds> <command...> : kill the command after <seconds>; exits 124 (timeout) or 142
# (the perl alarm fallback, for systems without `timeout`, such as macOS) when it does.
bounded() {
  secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  else perl -e '$t = shift; alarm $t; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$secs" "$@"
  fi
}

# preflight : the tools this subcommand needs are installed (checked before setup creates any
# repo), and gh is signed in with the repo scope; a missing delete_repo only warns.
# Sets LOGIN and CAN_DELETE (yes, no, or unknown when the token has no classic scopes).
preflight() {
  command -v gh >/dev/null 2>&1 || die "gh is not installed (https://cli.github.com)"
  case "$SUB" in
    solve|run) command -v claude >/dev/null 2>&1 || die "claude is not installed" ;;
  esac
  case "$SUB" in
    solve|check|run) command -v python3 >/dev/null 2>&1 || die "python3 is not installed" ;;
  esac
  out="$(gh api -i user 2>&1)" \
    || die "gh is not authenticated; run \`gh auth login\` ($(printf '%s' "$out" | tail -n 1))"
  out="$(printf '%s\n' "$out" | tr -d '\r')"
  LOGIN="$(printf '%s\n' "$out" | sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$LOGIN" ] || die "could not read the gh user from \`gh api user\`"
  if ! printf '%s\n' "$out" | grep -qi '^x-oauth-scopes:'; then
    warn "cannot read the token's scopes (not a classic token?); assuming it can create repos"
    CAN_DELETE=unknown
    return 0
  fi
  scopes=", $(printf '%s\n' "$out" | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' | head -n 1),"
  case "$scopes" in
    *", repo,"*) ;;
    *) die "the gh token lacks the repo scope; run \`gh auth refresh -s repo\`" ;;
  esac
  case "$scopes" in
    *", delete_repo,"*) CAN_DELETE=yes ;;
    *) CAN_DELETE=no
       warn "the gh token lacks delete_repo: cleanup will list repos instead of deleting them" ;;
  esac
}

if [ "$DRY" -eq 0 ]; then
  preflight
  tmp="$(mktemp -d)" && [ -n "$tmp" ] || die "mktemp failed"
  trap 'rm -rf "$tmp"' EXIT
fi
OWNER_SHOWN="${OWNER:-<gh user>}"

cmd_setup() {
  task="$1"; md="$TASKS/$task/task.md"; name="octo-bench-$task-$RUN_ID"
  title="$(task_part "$md" title)"; kind="$(task_part "$md" kind)"
  if [ "$DRY" -eq 1 ]; then
    echo "setup $task"
    echo "  repo:  $OWNER_SHOWN/$name (private): bench/tasks/$task/seed/ + .claude/settings.json"
    echo "  issue: $title [label: $kind]"
    echo "  \$ gh repo create $OWNER_SHOWN/$name --private --source <seed copy> --push"
    echo "  \$ gh label create $kind --repo $OWNER_SHOWN/$name --force"
    echo "  \$ gh issue create --repo $OWNER_SHOWN/$name --title <title> --label $kind \\"
    echo "      --body-file -  (body: task.md after the title)"
    return 0
  fi
  repo="${OWNER:-$LOGIN}/$name"; dir="$tmp/seed-$task"
  mkdir -p "$dir/.claude" && cp -R "$TASKS/$task/seed/." "$dir/" || die "could not copy seed/"
  # Per README -> Unattended runs: the agent's gh, git, and test commands never prompt. The
  # file tools too, since a skill's tool permissions may not carry over to its subagents (the
  # implementer's fix rounds edit files), and this repo is throwaway.
  printf '%s\n' '{' '  "permissions": {' \
    '    "allow": ["Bash(gh:*)", "Bash(git:*)", "Bash(make test:*)",' \
    '      "Read", "Edit", "Write", "Grep", "Glob"]' '  }' '}' \
    >"$dir/.claude/settings.json"
  { git -c init.defaultBranch=main init -q "$dir" && git -C "$dir" add -A \
    && git -C "$dir" -c user.name=octo-bench -c user.email=octo-bench@example.invalid \
         -c commit.gpgsign=false commit -q --no-verify -m "seed: $task"; } \
    || die "could not commit the seed"
  gh repo create "$repo" --private --source "$dir" --push >&2 || die "could not create $repo"
  gh label create "$kind" --repo "$repo" --force >/dev/null || die "could not create label $kind"
  url="$(task_part "$md" body \
    | gh issue create --repo "$repo" --title "$title" --label "$kind" --body-file -)" \
    || die "could not file the issue in $repo"
  echo "$repo ${url##*/}"
}

cmd_solve() {
  repo="$1"; issue="$2"; out="$RESULTS/${repo#*/}.solve.json"
  if [ "$DRY" -eq 1 ]; then
    echo "solve $repo #$issue"
    echo "  \$ gh repo clone $repo <clone>"
    echo "  \$ claude -p \"/octoperator:auto $issue\" --output-format json --plugin-dir $PLUGIN_DIR"
    echo "    (in <clone>, killed after ${SOLVE_TIMEOUT}s)"
    echo "  save: $out"
    return 0
  fi
  dir="$tmp/solve-${repo#*/}"
  gh repo clone "$repo" "$dir" -- -q || die "could not clone $repo"
  sha="$(git -C "$PLUGIN_DIR" rev-parse HEAD 2>/dev/null)"
  start="$(date +%s)"
  (cd "$dir" && bounded "$SOLVE_TIMEOUT" claude -p "/octoperator:auto $issue" \
    --output-format json --plugin-dir "$PLUGIN_DIR") </dev/null >"$dir.out" 2>"$dir.err"
  rc=$?
  mkdir -p "$RESULTS" || die "could not create $RESULTS"
  python3 - "$dir.out" "$sha" "$rc" "$(($(date +%s) - start))" >"$out" <<'PY' \
    || die "could not save $out"
import json, sys
try:
    claude = json.load(open(sys.argv[1]))
except ValueError:
    claude = None
json.dump({"octoperator_sha": sys.argv[2] or None, "exit": int(sys.argv[3]),
           "duration_s": int(sys.argv[4]), "claude": claude}, sys.stdout, indent=2)
print()
PY
  echo "$out"
  if [ "$rc" -ne 0 ]; then
    warn "claude exited $rc (124 or 142: timed out after ${SOLVE_TIMEOUT}s); its stderr ends:"
    tail -n 20 "$dir.err" >&2
    return 1
  fi
}

# metrics <task> <repo> <check passed: true|false> <pr view json> <solve json> <sha> : print
# the result line. (A function, not a heredoc in $(...), which bash 3.2 misparses.)
metrics() {
  python3 - "$@" <<'PY'
import json, os, re, sys
task, repo, passed, view_path, solve_path, sha = sys.argv[1:7]
view = json.load(open(view_path)) or {}
# Only Octoperator's own reviews count: the review skill posts a verdict line, as
# "**Intended verdict: ...**" when it had to downgrade a self-review to a comment.
octo = re.compile(r"intended verdict|^\*\*verdict:", re.I | re.M)
reviews = [r.get("body") or "" for r in view.get("reviews") or []]
reviews = [b for b in reviews if octo.search(b)]
def has(body, *names):
    return any(re.search(r"^###\s+" + n, body, re.I | re.M) for n in names)
minor_only = sum(1 for b in reviews if has(b, "Minor") and not has(b, "Blocker", "Major"))
verdict = None
if reviews:
    m = re.search(r"verdict:\W*(approve|request_changes|comment)", reviews[-1], re.I)
    verdict = m.group(1).lower() if m else None
merged = view.get("state") == "MERGED"
if merged: held = None
elif not view: held = "no PR"
elif view.get("state") == "CLOSED": held = "closed"
elif view.get("isDraft"): held = "draft"
elif not reviews: held = "not reviewed"
elif verdict == "request_changes": held = "review blocking"
elif view.get("mergeStateStatus") != "CLEAN": held = "merge state %s" % view.get("mergeStateStatus")
else: held = "not merged"
solve = {}
if os.path.exists(solve_path):
    try:
        solve = json.load(open(solve_path)) or {}
    except ValueError:
        pass
claude = solve.get("claude") or {}
model = claude.get("model")
if not model and claude.get("modelUsage"):
    model = max(claude["modelUsage"].items(), key=lambda kv: kv[1].get("costUSD") or 0)[0]
print(json.dumps({
    "task": task, "repo": repo, "pr": view.get("number"), "merged": merged,
    "check_passed": passed == "true", "success": merged and passed == "true",
    "fix_rounds": max(len(reviews) - 1, 0), "minor_only_rounds": minor_only,
    "held_reason": held, "cost_usd": claude.get("total_cost_usd"),
    "turns": claude.get("num_turns"), "duration_s": solve.get("duration_s"),
    "octoperator_sha": solve.get("octoperator_sha") or sha or None, "model": model}))
PY
}

cmd_check() {
  task="$1"; repo="$2"; run_id="$3"
  lines="$RESULTS/$run_id.jsonl"; solve="$RESULTS/${repo#*/}.solve.json"
  if [ "$DRY" -eq 1 ]; then
    echo "check $task $repo"
    echo "  \$ gh repo clone $repo <clone>"
    echo "  \$ bash check.sh <clone>  (in bench/tasks/$task/, killed after ${CHECK_TIMEOUT}s)"
    echo "  \$ gh pr list --repo $repo --state all --limit 1 --json number"
    echo "  \$ gh pr view <pr> --repo $repo --json number,state,isDraft,mergeStateStatus,reviews"
    echo "  append: $lines"
    return 0
  fi
  dir="$tmp/check-${repo#*/}"
  gh repo clone "$repo" "$dir" -- -q || die "could not clone $repo"
  (cd "$TASKS/$task" && bounded "$CHECK_TIMEOUT" bash ./check.sh "$dir") </dev/null \
    >"$dir.log" 2>&1
  rc=$?
  passed=false
  if [ "$rc" -eq 0 ]; then passed=true
  else warn "check.sh failed (exit $rc):"; tail -n 20 "$dir.log" >&2
  fi
  gh pr list --repo "$repo" --state all --limit 1 --json number >"$dir.list" \
    || die "could not list $repo's PRs"
  pr="$(python3 -c 'import json, sys
l = json.load(open(sys.argv[1])); print(l[0]["number"] if l else "")' "$dir.list")" \
    || die "could not parse $repo's PR list"
  if [ -n "$pr" ]; then
    gh pr view "$pr" --repo "$repo" --json number,state,isDraft,mergeStateStatus,reviews \
      >"$dir.view" || die "could not read $repo PR #$pr"
  else
    echo null >"$dir.view"
  fi
  sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
  line="$(metrics "$task" "$repo" "$passed" "$dir.view" "$solve" "$sha")" \
    || die "could not compute the metrics"
  mkdir -p "$RESULTS" && printf '%s\n' "$line" >>"$lines" || die "could not write $lines"
  echo "$line"
}

cmd_cleanup() {
  if [ "$DRY" -eq 1 ]; then
    echo "cleanup run $RUN_ID"
    for d in "$TASKS"/*/; do
      echo "  \$ gh repo delete $OWNER_SHOWN/octo-bench-$(basename "$d")-$RUN_ID --yes  (if any)"
    done
    return 0
  fi
  owner="${OWNER:-$LOGIN}"
  names="$(gh repo list "$owner" --limit 1000 --json name --jq '.[].name')" \
    || die "could not list $owner's repos"
  left="" found=0
  for d in "$TASKS"/*/; do
    repo="$owner/octo-bench-$(basename "$d")-$RUN_ID"
    printf '%s\n' "$names" | grep -Fxq "${repo#*/}" || continue
    found=1
    if [ "$CAN_DELETE" != no ] && gh repo delete "$repo" --yes >&2; then echo "deleted $repo"
    else left="$left $repo"
    fi
  done
  [ "$found" -eq 1 ] || echo "no repos for run $RUN_ID under $owner"
  [ -z "$left" ] && return 0
  warn "not deleted (needs \`gh auth refresh -s delete_repo\`, then cleanup again):"
  for r in $left; do echo "  $r" >&2; done
  return 1
}

cmd_run() {
  total=0 failed=0 unknown_tasks=""
  for t in $TASK_LIST; do
    if [ -n "$MAX_COST" ] && awk -v t="$total" -v c="$MAX_COST" 'BEGIN { exit !(t > c) }'; then
      warn "spent \$$total, past --max-cost-usd $MAX_COST: not starting $t or later tasks"
      return 1
    fi
    if [ "$DRY" -eq 1 ]; then
      cmd_setup "$t"
      cmd_solve "$OWNER_SHOWN/octo-bench-$t-$RUN_ID" "<issue#>"
      cmd_check "$t" "$OWNER_SHOWN/octo-bench-$t-$RUN_ID" "$RUN_ID"
      continue
    fi
    # Subshells: a failing step's `die` ends that step, not the whole run.
    out="$(cmd_setup "$t")" || { warn "setup failed for $t; skipping it"; failed=1; continue; }
    repo="${out% *}"; solve="$RESULTS/${repo#*/}.solve.json"
    rm -f "$solve"
    (cmd_solve "$repo" "${out##* }") || failed=1
    (cmd_check "$t" "$repo" "$RUN_ID") || failed=1
    # No solve JSON: solve failed before claude started, so it cost nothing. JSON without a
    # cost: claude ran (maybe timed out, the costliest case) and its spend is unknown.
    cost="$(python3 -c 'import json, os, sys
if not os.path.exists(sys.argv[1]): print(0); sys.exit()
try: s = json.load(open(sys.argv[1]))
except ValueError: print("unknown ?"); sys.exit()
s = s if isinstance(s, dict) else {}
c = s.get("claude") if isinstance(s.get("claude"), dict) else {}
c = c.get("total_cost_usd")
ok = isinstance(c, (int, float)) and not isinstance(c, bool)
print(c if ok else "unknown %s" % s.get("exit", "?"))' "$solve")" || cost="unknown ?"
    case "$cost" in
      unknown*)
        if [ -n "$MAX_COST" ]; then
          warn "cost of $t unknown (claude exit ${cost#unknown }); not starting more tasks"
          echo "run $RUN_ID: total cost \$$total, plus $t's unknown cost" >&2
          return 1
        fi
        unknown_tasks="$unknown_tasks $t"
        cost=0 ;;
    esac
    total="$(awk -v t="$total" -v c="$cost" 'BEGIN { print t + c }')"
  done
  if [ "$DRY" -eq 0 ]; then
    if [ -n "$unknown_tasks" ]; then
      echo "run $RUN_ID: total cost \$$total, plus unknown cost for:$unknown_tasks" >&2
    else
      echo "run $RUN_ID: total cost \$$total" >&2
    fi
  fi
  [ "$failed" -eq 0 ]
}

case "$SUB" in
  setup) cmd_setup "$P1" ;;
  solve) cmd_solve "$P1" "$P2" ;;
  check) cmd_check "$P1" "$P2" "$CHECK_RUN_ID" ;;
  cleanup) cmd_cleanup ;;
  run) cmd_run ;;
esac
