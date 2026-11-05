#!/usr/bin/env bash
# octo-ledger-state.sh — decide autopilot's next move from its run ledger and the evals metric.
#
# Usage:
#   octo-ledger-state.sh --repo OWNER/NAME --runs N [--issue LEDGER] [--metric P/T|none] [--resume]
#
# Applies the rules in skills/autopilot/references/ledger.md (the run ledger). An entry is a
# ledger comment by an OWNER, MEMBER, or COLLABORATOR whose body holds exactly one ```json block
# parsing to an object with all nine keys and a known kind. A numeric metric is an object with
# whole numbers 0 <= passed <= total, total >= 1; it is all-pass when passed == total. Each entry
# is compared with the high-water mark: the highest numeric passed among the older entries of
# the walk and the entry that ends it. An `observe` entry never gains; an entry with a numeric
# metric, when there is a mark, gains only if passed exceeds it; otherwise it gains when
# merged >= 1. The walk runs newest first and stops at the first `reset` or all-pass entry
# (--resume: it is empty, as the reset entry about to be appended ends it). Converged: the
# newest N entries of the walk exist and none gains. With no --issue (no ledger yet) the walk is
# empty.
#
# --metric is this run's pass rate (default none), octo-evals-metric.sh's `rate:` value. The
# decision is `observe` when converged and `build` otherwise; `all-pass` reports whether every
# eval passes, which the skill checks first (Run ledger → All evals pass).
#
# `planning-failed` reads the newest valid `run` or `reset` entry (observe entries plan nothing,
# so they are passed over): when it is a `run` entry whose optional `planning_failed` key is an
# object with a 40-digit `tip` and a string `reason`, that run's next-milestone planning failed
# at that tip. octo-milestone-gate.sh's --failed-tip takes the tip. With --resume it is none.
#
# Prints seven lines:
#   entries: <k> (since the last reset | since the last all-pass entry | since --resume | all)
#   skipped: none | <count> (<authorAssociation>), …   (entry-shaped comments by other authors)
#   streak: <entries without a gain, newest first>/<N>
#   high-water: none | <P>   (the mark this run's entry must exceed; with --resume, --metric's P,
#                            which the reset entry about to be appended carries)
#   all-pass: yes | no
#   planning-failed: none | <tip> <reason, at most 80 characters on one line>
#   decision: observe | build
# Read-only, REST only: every page of `GET repos/OWNER/NAME/issues/LEDGER/comments`, so it works
# where GraphQL is refused (a Claude Code cloud session).
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
all_pass=no resume_mark=none
if [ "$METRIC" != none ]; then
  [[ "$METRIC" =~ ^$int/$int$ ]] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] \
    && [ "${BASH_REMATCH[2]}" -ge 1 ] \
    || { echo "--metric must be P/T (whole numbers, P <= T, T >= 1) or none" >&2; exit 2; }
  [ "${BASH_REMATCH[1]}" -eq "${BASH_REMATCH[2]}" ] && all_pass=yes
  # --resume appends a reset entry carrying this metric, so its P is the mark the run must beat.
  [ "$RESUME" = false ] || resume_mark="${BASH_REMATCH[1]}"
fi

if [ -z "$ISSUE" ]; then
  printf 'entries: 0 (no ledger yet)\nskipped: none\nstreak: 0/%s\nhigh-water: %s\nall-pass: %s\nplanning-failed: none\ndecision: build\n' \
    "$RUNS" "$resume_mark" "$all_pass"
  exit 0
fi

# REST serves the comments oldest first, a page at a time, and gh's --jq runs once per page, so
# the filter reads each comment on its own and the walk below, in awk, sees the whole ledger.
# Every type test sits in an `if`, so a malformed entry never makes jq fail. One tab-separated
# line per comment whose body holds ```json:
#   <author_association> <kind, or - when it is no valid entry> <passed, or - when the metric is
#   not numeric> <all-pass: 1 or 0> <merged >= 1: 1 or 0> <planning_failed: <tip> <reason> | none>
# planning_failed is read for a run entry only. Its reason holds no control character (so no
# tab), is at most 80 characters, and comes last.
# shellcheck disable=SC2016  # backticks and \(...) belong to the jq filter
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
def failed($pf): if ($pf | type) == "object" and (($pf.tip | type) == "string")
    and ($pf.tip | test("^[0-9a-f]{40}$")) and (($pf.reason | type) == "string") then
    "\($pf.tip) \($pf.reason | gsub("[[:cntrl:]]"; " ") | .[0:80])"
  else "none" end;
.[] | select((.body // "") | contains("```json"))
| "\(.author_association)\t" + ([entry][0]
  | if . == null then "-\t-\t0\t0\tnone"
    else (if .kind == "run" then .planning_failed else null end) as $pf
      | "\(.kind)\t\(if .metric | num then .metric.passed else "-" end)"
        + "\t\(if (.metric | num) and (.metric.passed == .metric.total) then 1 else 0 end)"
        + "\t\(if ((.merged | type) == "number") and (.merged >= 1) then 1 else 0 end)"
        + "\t\(failed($pf))"
    end)'

err="$(mktemp)" && [ -n "$err" ] || { echo "mktemp failed" >&2; exit 3; }
trap 'rm -f "$err"' EXIT
lines="$(gh api "repos/$REPO/issues/$ISSUE/comments?per_page=100" --paginate --jq "$filter" \
  2>"$err")" || { cat "$err" >&2; exit 3; }

# The walk, over the valid entries from allowed authors, newest first: v[j] is entry n - j.
# mark(lo, hi) is the highest numeric passed among v[lo..hi], or "" for none.
printf '%s' "$lines" | LC_ALL=C awk -F '\t' -v runs="$RUNS" -v resume="$RESUME" \
  -v markp="$resume_mark" -v allpass="$all_pass" '
  function mark(lo, hi,    j, m) {
    m = ""
    for (j = lo; j <= hi && j < n; j++)
      if (P[n - j] != "-" && (m == "" || P[n - j] + 0 > m + 0)) m = P[n - j]
    return m
  }
  $1 == "OWNER" || $1 == "MEMBER" || $1 == "COLLABORATOR" {
    if ($2 != "-") { n++; K[n] = $2; P[n] = $3; A[n] = $4; M[n] = $5; F[n] = $6 }
    next
  }
  { if (!($1 in skip)) names[++nn] = $1; skip[$1]++ }
  END {
    hit = -1
    for (j = 0; j < n; j++) if (K[n - j] == "reset" || A[n - j] == 1) { hit = j; break }
    if (resume == "true") { stop = 0; why = "since --resume" }
    else if (hit < 0) { stop = n; why = "all" }
    else {
      stop = hit
      why = (K[n - hit] == "reset") ? "since the last reset" : "since the last all-pass entry"
    }
    # An entry gains against the mark of the older entries of the walk and the one that ends it.
    streak = stop
    for (j = 0; j < stop; j++) {
      i = n - j; m = mark(j + 1, stop)
      if (K[i] == "observe") g = 0
      else if (P[i] != "-" && m != "") g = (P[i] + 0 > m + 0)
      else g = (M[i] == 1)
      if (g) { streak = j; break }
    }
    hw = (resume == "true") ? markp : mark(0, stop)
    if (hw == "") hw = "none"
    # The newest run or reset entry: a run entry names the tip its planning failed at.
    pf = "none"
    for (j = 0; resume != "true" && j < n; j++)
      if (K[n - j] != "observe") { if (K[n - j] == "run") pf = F[n - j]; break }
    # The other authors, by name, as "<count> (<author_association>)".
    for (a = 2; a <= nn; a++)
      for (b = a; b > 1 && names[b - 1] > names[b]; b--) {
        t = names[b]; names[b] = names[b - 1]; names[b - 1] = t
      }
    skipped = ""
    for (a = 1; a <= nn; a++) skipped = skipped (a > 1 ? ", " : "") skip[names[a]] " (" names[a] ")"
    printf "entries: %d (%s)\n", stop, why
    printf "skipped: %s\n", (skipped == "") ? "none" : skipped
    printf "streak: %d/%s\n", streak, runs
    printf "high-water: %s\n", hw
    printf "all-pass: %s\n", allpass
    printf "planning-failed: %s\n", pf
    printf "decision: %s\n", (streak >= runs + 0) ? "observe" : "build"
  }'
