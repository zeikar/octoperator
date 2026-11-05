#!/usr/bin/env bash
# octo-after-merge.sh — after auto merges a PR, close what it finished: each issue the PR closes
# that GitHub left open, and each epic of those issues whose children are now all closed.
#
# Usage:
#   octo-after-merge.sh --repo OWNER/NAME --pr NUMBER [--tries N] [--interval SECONDS]
#
# REST only (`gh api repos/...`): a Claude Code cloud session's proxy refuses GraphQL, so no
# `gh api graphql` and no `gh issue` / `gh pr` porcelain. Acts only on a PR merged into the default
# branch. Its issues are the `#N` and `OWNER/NAME#N` references in this repo that follow a closing
# keyword (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved) in its body, as
# GitHub links them; a pull request is never closed. GitHub usually closes them within seconds,
# so an open one is re-read up to --tries times in all (default 3), --interval seconds apart
# (default 5), before it is closed as completed with the comment `Closed by #<pr> (merged)`.
#
# The epics of each closed issue are its native parent (`GET .../issues/N/parent`) and every open
# `epic` issue whose `## Children` checklist has an item `- [ ] #N`. An epic is closed, with a
# comment naming the PR, only when it is open and labeled `epic`, it has at least one child,
# every child (its sub-issues and its checklist items together) is closed, and every checklist
# item names an issue as `#N`.
#
# Prints one line per action (`closed issue #N`, `closed epic #E`), a `warn: ...` line for each
# read or write that failed, or `nothing to close`. Exits 0 even then, since the merge already
# happened; exits 2 only on bad arguments.
set -uo pipefail

REPO="" PR="" TRIES=3 INTERVAL=5
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     need_value "$@"; REPO="$2"; shift 2 ;;
    --pr)       need_value "$@"; PR="$2"; shift 2 ;;
    --tries)    need_value "$@"; TRIES="$2"; shift 2 ;;
    --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

USAGE="Usage: octo-after-merge.sh --repo OWNER/NAME --pr NUMBER [--tries N] [--interval SECONDS]"
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

ACTED=0 WARNED=0
warn() { WARNED=1; echo "warn: $*"; }
done_line() { ACTED=1; echo "$*"; }
finish() {
  [ "$ACTED" -eq 1 ] || [ "$WARNED" -eq 1 ] || echo "nothing to close"
  exit 0
}

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
not_found() { case "$ERR" in *"(HTTP 404)"*) return 0 ;; esac; return 1; }
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

# --- the PR and the issues it closes ---------------------------------------------------------
api "repos/$REPO/pulls/$PR" \
  --jq '"\(.merged)\t\(.base.ref)\t\(.base.repo.default_branch)", (.body // "")' || {
  warn "could not read PR #$PR: $ERR"; finish; }
META=${OUT%%$'\n'*} BODY=""
case "$OUT" in *$'\n'*) BODY=${OUT#*$'\n'} ;; esac
IFS=$'\t' read -r MERGED BASE DEFAULT <<<"$META"
[ "$MERGED" = true ] || { warn "PR #$PR is not merged; nothing closed"; finish; }
# GitHub links closing keywords only on a PR into the default branch.
[ "$BASE" = "$DEFAULT" ] || finish

ISSUES=""
while IFS= read -r m; do
  ref=${m##*[[:space:]]}
  case "$ref" in
    \#*) ;;
    *) [ "$(lower "${ref%%#*}")" = "$REPO_LC" ] || continue ;;
  esac
  n=$((10#${ref##*#}))
  [ "$n" -ge 1 ] || continue
  case " $ISSUES " in *" $n "*) ;; *) ISSUES="$ISSUES $n" ;; esac
done < <(printf '%s\n' "$BODY" | tr -d '\r' |
  grep -oiE '(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+([[:alnum:]._-]+/[[:alnum:]._-]+)?#[0-9]+')

CLOSED=""
for n in $ISSUES; do
  try=1
  while :; do
    api "repos/$REPO/issues/$n" --jq '"\(.state)\t\(.pull_request != null)"' || {
      warn "could not read #$n: $ERR"; continue 2; }
    IFS=$'\t' read -r state is_pr <<<"$OUT"
    [ "$is_pr" = false ] || continue 2
    [ "$state" = open ] && [ "$try" -lt "$TRIES" ] || break
    try=$((try + 1))
    sleep "$INTERVAL"
  done
  if [ "$state" = open ]; then
    close_issue "$n" "Closed by #$PR (merged)" || continue
    done_line "closed issue #$n"
  fi
  CLOSED="$CLOSED $n"
done
[ -n "$CLOSED" ] || finish

# --- their epics -----------------------------------------------------------------------------
# Every open epic's `## Children` checklist items, one `<epic><TAB><child>` line each, `?` for an
# item that names no issue. The section runs to the next `#` or `##` heading.
api "repos/$REPO/issues?labels=epic&state=open&per_page=100" --paginate \
  --jq '.[] | select(.pull_request == null) | .number as $n | (.body // "") | split("\n")[] | "\($n)\t\(.)"' || {
  warn "could not list open epics: $ERR"; finish; }
CHECKLISTS=$(printf '%s\n' "$OUT" | awk '
  { i = index($0, "\t"); if (i == 0) next
    e = substr($0, 1, i - 1); l = substr($0, i + 1); sub(/\r$/, "", l)
    if (e != cur) { cur = e; inside = 0 }
    if (tolower(l) ~ /^##[ \t]+children[ \t]*$/) { inside = 1; next }
    if (l ~ /^##?[ \t]/) { inside = 0; next }
    if (!inside || l !~ /^[ \t]*[-*+][ \t]+\[[ xX]\]/) next
    if (l ~ /^[ \t]*[-*+][ \t]+\[[ xX]\][ \t]+#[0-9]+([^0-9]|$)/) {
      match(l, /#[0-9]+/); print e "\t" substr(l, RSTART + 1, RLENGTH - 1)
    } else print e "\t?"
  }')

CANDIDATES=""
add_candidate() { case " $CANDIDATES " in *" $1 "*) ;; *) CANDIDATES="$CANDIDATES $1" ;; esac; }
for n in $CLOSED; do
  if api "repos/$REPO/issues/$n/parent" --jq '"\(.number)\t\(.repository_url)"'; then
    IFS=$'\t' read -r parent url <<<"$OUT"
    # A parent in another repo is left alone: this helper writes only to --repo.
    [ "$(lower "${url##*/repos/}")" != "$REPO_LC" ] || add_candidate "$parent"
  elif ! not_found; then
    warn "could not read the parent of #$n: $ERR"
  fi
  while IFS=$'\t' read -r e c; do
    [ "$c" != "$n" ] || add_candidate "$e"
  done <<<"$CHECKLISTS"
done

for e in $CANDIDATES; do
  api "repos/$REPO/issues/$e" \
    --jq '"\(.state)\t\(any(.labels[]; (.name | ascii_downcase) == "epic"))\t\(.pull_request != null)"' || {
    warn "could not read epic #$e: $ERR"; continue; }
  IFS=$'\t' read -r state is_epic is_pr <<<"$OUT"
  [ "$state" = open ] && [ "$is_epic" = true ] && [ "$is_pr" = false ] || continue

  # <child><TAB><state> lines: the sub-issues first, then checklist items they don't cover.
  if api "repos/$REPO/issues/$e/sub_issues?per_page=100" --paginate --jq '.[] | "\(.number)\t\(.state)"'; then
    KIDS=$OUT
  elif not_found; then
    KIDS=""
  else
    warn "could not list the sub-issues of epic #$e: $ERR"; continue
  fi
  open_kid="" total=0
  while IFS=$'\t' read -r c s; do
    [ -n "$c" ] || continue
    total=$((total + 1)); [ "$s" = closed ] || open_kid=${open_kid:-$c}
  done <<<"$KIDS"
  while IFS=$'\t' read -r ce c; do
    [ "$ce" = "$e" ] || continue
    [ "$c" != "?" ] || { open_kid=${open_kid:-"an item with no issue number"}; continue; }
    printf '%s\n' "$KIDS" | grep -q "^$c"$'\t' && continue
    api "repos/$REPO/issues/$c" --jq '.state' || {
      warn "could not read #$c, a child of epic #$e: $ERR"; continue 2; }
    total=$((total + 1)); [ "$OUT" = closed ] || open_kid=${open_kid:-$c}
    KIDS="$KIDS"$'\n'"$c"$'\t'"$OUT"
  done <<<"$CHECKLISTS"
  [ "$total" -ge 1 ] && [ -z "$open_kid" ] || continue

  close_issue "$e" "All children of this epic are closed; closed after #$PR merged." || continue
  done_line "closed epic #$e"
done
finish
