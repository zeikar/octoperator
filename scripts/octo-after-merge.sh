#!/usr/bin/env bash
# octo-after-merge.sh — after auto merges a PR, close what it finished: the issue the PR closes,
# if GitHub left it open, and each epic of that issue whose children are now all closed.
#
# Usage:
#   octo-after-merge.sh --repo OWNER/NAME --pr NUMBER [--issue NUMBER] [--tries N] [--interval SECONDS]
#
# REST only (`gh api repos/...`): a Claude Code cloud session's proxy refuses GraphQL, so no
# `gh api graphql` and no `gh issue` / `gh pr` porcelain. --issue is the one issue the PR closes,
# which auto passes from its own state rather than this helper parsing the PR body; without it
# (a PR that closes no issue) there is nothing to close and no epic is checked. Acts only on a PR
# merged into the default branch, and never closes a pull request. GitHub usually closes the issue
# within seconds, so an open one is re-read up to --tries times in all (default 3), --interval
# seconds apart (default 5), before it is closed as completed with the comment
# `Closed by #<pr> (merged)`.
#
# The issue's epics are its native parent (`GET .../issues/N/parent`) and every open `epic` issue
# whose `## Children` section has a list item (`-`, `*`, `+`, or `1.`, with or without a checkbox)
# for `#N`. An epic is closed, with a comment naming the PR, only when it is open and labeled
# `epic`, it has at least one child, every child (its sub-issues, from any repo, and its list
# items together) is closed, and every list item starts with an issue as `#N`.
#
# Prints one line per action (`closed issue #N`, `closed epic #E`), a `warn: ...` line for each
# read or write that failed, `warn: epic #E kept open: a ## Children item does not start with #N`
# when that item is all that keeps an epic open, or `nothing to close`. Exits 0 even then, since
# the merge already happened; exits 2 only on bad arguments.
set -uo pipefail

REPO="" PR="" ISSUE="" TRIES=3 INTERVAL=5
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     need_value "$@"; REPO="$2"; shift 2 ;;
    --pr)       need_value "$@"; PR="$2"; shift 2 ;;
    --issue)    need_value "$@"; ISSUE="$2"; shift 2 ;;
    --tries)    need_value "$@"; TRIES="$2"; shift 2 ;;
    --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

USAGE="Usage: octo-after-merge.sh --repo OWNER/NAME --pr NUMBER [--issue NUMBER] [--tries N] [--interval SECONDS]"
[ -n "$REPO" ] && [ -n "$PR" ] || { echo "$USAGE" >&2; exit 2; }
case "$REPO" in
  */*/* | /* | */ | *[!A-Za-z0-9._/-]*) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
  */*) ;;
  *) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
esac
case "$PR$TRIES$INTERVAL" in
  *[!0-9]*) echo "--pr, --tries, and --interval must be non-negative integers" >&2; exit 2 ;;
esac
[ "$PR" -ge 1 ] && [ "$TRIES" -ge 1 ] || { echo "--pr and --tries must be at least 1" >&2; exit 2; }
# Nine digits at most, so shell arithmetic and the API both take it as is.
if [ -n "$ISSUE" ] && ! [[ "$ISSUE" =~ ^[1-9][0-9]{0,8}$ ]]; then
  echo "--issue must be an issue number (1 to 9 digits, no leading zero)" >&2; exit 2
fi

ACTED=0 WARNED=0
warn() { WARNED=1; echo "warn: $*"; }
done_line() { ACTED=1; echo "$*"; }
finish() {
  [ "$ACTED" -eq 1 ] || [ "$WARNED" -eq 1 ] || echo "nothing to close"
  exit 0
}

# No issue (a PR that closes none): nothing to close, and no issue whose epic to check.
[ -n "$ISSUE" ] || finish

ERRF=$(mktemp) || { warn "mktemp failed; nothing checked"; finish; }
trap 'rm -f "$ERRF"' EXIT

# api <gh api args...> : stdout in $OUT, gh's last stderr line in $ERR; returns gh's status. On
# failure gh prints the error body on stdout, so $OUT is only meaningful on success.
OUT="" ERR=""
api() {
  local rc
  OUT=$(gh api "$@" 2>"$ERRF"); rc=$?
  ERR=$(tail -n 1 "$ERRF")
  [ -n "$ERR" ] || ERR="gh exited $rc with no error output"
  return "$rc"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
REPO_LC=$(lower "$REPO")

# close_issue <n> <comment> : close <n> as completed, then comment. Returns 1 if the close failed.
close_issue() {
  api -X PATCH "repos/$REPO/issues/$1" -f state=closed -f state_reason=completed --silent || {
    warn "could not close #$1: $ERR"; return 1; }
  api "repos/$REPO/issues/$1/comments" -f body="$2" --silent ||
    warn "closed #$1 but could not comment: $ERR"
  return 0
}

# --- the PR and its issue --------------------------------------------------------------------
api "repos/$REPO/pulls/$PR" --jq '"\(.merged)\t\(.base.ref)\t\(.base.repo.default_branch)"' || {
  warn "could not read PR #$PR: $ERR"; finish; }
IFS=$'\t' read -r MERGED BASE DEFAULT <<<"$OUT"
[ "$MERGED" = true ] || { warn "PR #$PR is not merged; nothing closed"; finish; }
# GitHub closes an issue from a PR only when it merges into the default branch.
[ "$BASE" = "$DEFAULT" ] || finish

n=$ISSUE try=1
while :; do
  api "repos/$REPO/issues/$n" --jq '"\(.state)\t\(.pull_request != null)"' || {
    warn "could not read #$n: $ERR"; finish; }
  IFS=$'\t' read -r state is_pr <<<"$OUT"
  [ "$is_pr" = false ] || { warn "#$n is a pull request; nothing closed"; finish; }
  [ "$state" = open ] && [ "$try" -lt "$TRIES" ] || break
  try=$((try + 1))
  sleep "$INTERVAL"
done
if [ "$state" = open ]; then
  close_issue "$n" "Closed by #$PR (merged)" || finish
  done_line "closed issue #$n"
fi

# --- its epics -------------------------------------------------------------------------------
# Every open epic's `## Children` list items, one `<epic><TAB><child>` line each, `?` for an item
# that does not start with an issue as `#N`. The section runs to the next `#` or `##` heading.
api "repos/$REPO/issues?labels=epic&state=open&per_page=100" --paginate \
  --jq '.[] | select(.pull_request == null) | .number as $n | (.body // "") | split("\n")[] | "\($n)\t\(.)"' || {
  warn "could not list open epics: $ERR"; finish; }
CHECKLISTS=$(printf '%s\n' "$OUT" | awk '
  { i = index($0, "\t"); if (i == 0) next
    e = substr($0, 1, i - 1); l = substr($0, i + 1); sub(/\r$/, "", l)
    if (e != cur) { cur = e; inside = 0 }
    if (tolower(l) ~ /^##[ \t]+children[ \t]*$/) { inside = 1; next }
    if (l ~ /^##?[ \t]/) { inside = 0; next }
    if (!inside || l !~ /^[ \t]*([-*+]|[0-9]+\.)[ \t]+/) next
    sub(/^[ \t]*([-*+]|[0-9]+\.)[ \t]+(\[[ xX]\][ \t]+)?/, "", l)
    c = "?"
    if (l ~ /^#[0-9]+([^0-9]|$)/) { match(l, /^#[0-9]+/); c = substr(l, 2, RLENGTH - 1) }
    sub(/^0+/, "", c); print e "\t" (c == "" ? "?" : c)
  }')

CANDIDATES=""
add_candidate() { case " $CANDIDATES " in *" $1 "*) ;; *) CANDIDATES="$CANDIDATES $1" ;; esac; }
if api "repos/$REPO/issues/$n/parent" --jq '"\(.number)\t\(.repository_url)"'; then
  IFS=$'\t' read -r parent url <<<"$OUT"
  # A parent in another repo is left alone: this helper writes only to --repo.
  [ "$(lower "${url##*/repos/}")" != "$REPO_LC" ] || add_candidate "$parent"
else
  # Only this 404 means "no parent"; any other failure, a bare 404 included, is unknown.
  case "$ERR" in
    *"No parent issue found (HTTP 404)"*) ;;
    *) warn "could not read the parent of #$n: $ERR" ;;
  esac
fi
while IFS=$'\t' read -r e c; do
  [ "$c" != "$n" ] || add_candidate "$e"
done <<<"$CHECKLISTS"

for e in $CANDIDATES; do
  api "repos/$REPO/issues/$e" \
    --jq '"\(.state)\t\(any(.labels[]; (.name | ascii_downcase) == "epic"))\t\(.pull_request != null)"' || {
    warn "could not read epic #$e: $ERR"; continue; }
  IFS=$'\t' read -r state is_epic is_pr <<<"$OUT"
  [ "$state" = open ] && [ "$is_epic" = true ] && [ "$is_pr" = false ] || continue

  # <owner/name><TAB><child><TAB><state> lines: the sub-issues first, from any repo, then the list
  # items they don't cover. Any failure here, a 404 included, leaves the children unknown.
  api "repos/$REPO/issues/$e/sub_issues?per_page=100" --paginate \
    --jq '.[] | "\(.repository_url | sub(".*/repos/"; "") | ascii_downcase)\t\(.number)\t\(.state)"' || {
    warn "could not list the sub-issues of epic #$e: $ERR"; continue; }
  KIDS=$OUT open_kid="" unnumbered="" total=0
  while IFS=$'\t' read -r r c s; do
    [ -n "$c" ] || continue
    total=$((total + 1)); [ "$s" = closed ] || open_kid=${open_kid:-"$r#$c"}
  done <<<"$KIDS"
  while IFS=$'\t' read -r ce c; do
    [ "$ce" = "$e" ] || continue
    [ "$c" != "?" ] || { unnumbered=1; continue; }
    # Covered only by a sub-issue of this repo with the same number.
    case $'\n'"$KIDS" in *$'\n'"$REPO_LC"$'\t'"$c"$'\t'*) continue ;; esac
    api "repos/$REPO/issues/$c" --jq '.state' || {
      warn "could not read #$c, a child of epic #$e: $ERR"; continue 2; }
    total=$((total + 1)); [ "$OUT" = closed ] || open_kid=${open_kid:-$c}
    KIDS="$KIDS"$'\n'"$REPO_LC"$'\t'"$c"$'\t'"$OUT"
  done <<<"$CHECKLISTS"
  [ -z "$open_kid" ] || continue
  # Every numbered child is closed, so that item alone keeps the epic open: say so.
  [ -z "$unnumbered" ] || {
    warn "epic #$e kept open: a ## Children item does not start with #N"; continue; }
  [ "$total" -ge 1 ] || continue

  close_issue "$e" "All children of this epic are closed; closed after #$PR merged." || continue
  done_line "closed epic #$e"
done
finish
