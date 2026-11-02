#!/usr/bin/env bash
# octo-ledger-state.sh — decide autopilot's next move from its run ledger and the evals metric.
#
# Usage:
#   octo-ledger-state.sh --repo OWNER/NAME --runs N [--issue LEDGER] [--metric P/T|none] [--resume]
#
# Applies the rules in skills/autopilot/SKILL.md → Run ledger and convergence. An entry is a
# ledger comment by an OWNER, MEMBER, or COLLABORATOR whose body holds exactly one ```json block
# parsing to an object with all nine keys and a known kind. A numeric metric is an object with
# whole numbers 0 <= passed <= total, total >= 1; it is all-pass when passed == total. Each entry
# is compared with the next older valid entry: an `observe` entry never gains; when both have a
# numeric metric, an entry gains only if passed rose; otherwise it gains when merged >= 1. The
# walk runs newest first and stops at the first `reset` or all-pass entry (--resume: it is
# empty, as the reset entry about to be appended ends it). Converged: the newest N entries of
# the walk exist and none gains. With no --issue (no ledger yet) the walk is empty.
#
# --metric is this run's pass rate (default none). The decision, in this order:
#   all-pass   the metric is numeric and all-pass: hand off to next-milestone planning
#   observe    converged
#   build      anything else
#
# Prints four lines:
#   entries: <k> (since the last reset | since the last all-pass entry | since --resume | all)
#   skipped: none | <count> (<authorAssociation>), …   (entry-shaped comments by other authors)
#   streak: <entries without a gain, newest first>/<N>
#   decision: all-pass | observe | build
# Read-only: one `gh issue view`.
#
# Exit codes: 0 decided, 2 bad arguments, 3 a gh error (the ledger is unreadable).
set -uo pipefail

REPO="" ISSUE="" RUNS="" METRIC=none RESUME=false
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   need_value "$@"; REPO="$2"; shift 2 ;;
    --issue)  need_value "$@"; ISSUE="$2"; shift 2 ;;
    --runs)   need_value "$@"; RUNS="$2"; shift 2 ;;
    --metric) need_value "$@"; METRIC="$2"; shift 2 ;;
    --resume) RESUME=true; shift ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$RUNS" ] || {
  echo "Usage: octo-ledger-state.sh --repo OWNER/NAME --runs N [--issue LEDGER]" \
    "[--metric P/T|none] [--resume]" >&2; exit 2; }
# At most 9 digits and no leading zero: the values go into the jq filter as number literals.
int='(0|[1-9][0-9]{0,8})'
[[ "$RUNS" =~ ^$int$ ]] && [ "$RUNS" -ge 1 ] || { echo "--runs must be a positive integer" >&2; exit 2; }
[ -z "$ISSUE" ] || [[ "$ISSUE" =~ ^$int$ ]] || { echo "--issue must be a number" >&2; exit 2; }
all_pass=false m=null
if [ "$METRIC" != none ]; then
  [[ "$METRIC" =~ ^$int/$int$ ]] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] \
    && [ "${BASH_REMATCH[2]}" -ge 1 ] \
    || { echo "--metric must be P/T (whole numbers, P <= T, T >= 1) or none" >&2; exit 2; }
  m="{\"passed\":${BASH_REMATCH[1]},\"total\":${BASH_REMATCH[2]}}"
  [ "${BASH_REMATCH[1]}" -eq "${BASH_REMATCH[2]}" ] && all_pass=true
fi

if [ -z "$ISSUE" ]; then
  decision=build
  [ "$all_pass" = false ] || decision=all-pass
  printf 'entries: 0 (no ledger yet)\nskipped: none\nstreak: 0/%s\ndecision: %s\n' "$RUNS" \
    "$decision"
  exit 0
fi

# gh's --jq has no --arg, so RUNS, the metric, and RESUME are written in as literals. Comments
# come oldest first. Every type test sits in an `if`, so a malformed entry never makes jq fail.
filter='
def keys9: ["time", "mode", "cycles_used", "merged", "held", "proposals_filed", "metric",
  "cost_usd", "kind"];
def entry: (.body | split("```json")) as $p
  | (if ($p | length) == 2 then ($p[1] | split("```")[0] | try fromjson catch null) else null end)
  | . as $o
  | if type == "object" then
      (if all(keys9[]; . as $k | $o | has($k)) and (.kind | IN("run", "observe", "reset"))
       then . else empty end)
    else empty end;
def num: if type == "object" then
    (if ((.passed | type) == "number") and ((.total | type) == "number") then
      (.passed == (.passed | floor)) and (.total == (.total | floor)) and (.passed >= 0)
        and (.total >= 1) and (.passed <= .total)
    else false end)
  else false end;
def allpass: (.metric | num) and (.metric.passed == .metric.total);
def gains($prev): if .kind == "observe" then false
  elif (.metric | num) and ($prev != null) and ($prev.metric | num) then
    .metric.passed > $prev.metric.passed
  else ((.merged | type) == "number") and (.merged >= 1) end;
[.comments[] | select(.body | contains("```json"))] as $c
| ($c | map(select(.authorAssociation | IN("OWNER", "MEMBER", "COLLABORATOR")))) as $ok
| ($c - $ok | group_by(.authorAssociation)
    | map("\(length) (\(.[0].authorAssociation))") | join(", ")) as $skipped
| [$ok | reverse | .[] | entry] as $v
| ([range(0; $v | length) | select($v[.] | (.kind == "reset") or allpass)] | .[0]) as $hit
| (if RESUME then 0 elif $hit == null then ($v | length) else $hit end) as $stop
| (if RESUME then "since --resume" elif $hit == null then "all"
   elif $v[$hit].kind == "reset" then "since the last reset"
   else "since the last all-pass entry" end) as $why
| [range(0; $stop) as $i | $v[$i] | gains($v[$i + 1])] as $g
| ([range(0; $g | length) | select($g[.])] | .[0] // ($g | length)) as $streak
| (METRIC) as $m
| "entries: \($stop) (\($why))",
  "skipped: \(if $skipped == "" then "none" else $skipped end)",
  "streak: \($streak)/RUNS",
  "decision: \(if ($m | num) and ($m.passed == $m.total) then "all-pass"
    elif $streak >= RUNS then "observe" else "build" end)"'
filter="${filter//RESUME/$RESUME}"
filter="${filter//METRIC/$m}"
filter="${filter//RUNS/$RUNS}"

err="$(mktemp)" && [ -n "$err" ] || { echo "mktemp failed" >&2; exit 3; }
trap 'rm -f "$err"' EXIT
gh issue view "$ISSUE" --repo "$REPO" --json comments --jq "$filter" 2>"$err" \
  || { cat "$err" >&2; exit 3; }
