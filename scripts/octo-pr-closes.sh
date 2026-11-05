#!/usr/bin/env bash
# octo-pr-closes.sh — list pull requests with the issues each one's body closes, over REST.
#
# Usage:
#   octo-pr-closes.sh --repo OWNER/NAME --pr N
#   octo-pr-closes.sh --repo OWNER/NAME --state open|closed|all [--limit N]
#
# REST has no `closingIssuesReferences`: that is a GraphQL field, and a Claude Code cloud
# session's proxy refuses GraphQL. So this reads each PR's body and finds GitHub's closing
# keywords in it: close, closes, closed, fix, fixes, fixed, resolve, resolves, or resolved, in
# any case, an optional `:`, then spaces and `#N`, `OWNER/NAME#N`, or
# `https://github.com/OWNER/NAME/issues/N`. A keyword counts wherever it stands, negated too
# ("this does not close #5" still closes #5 on GitHub). Text GitHub never links is skipped:
# fenced code blocks (``` or ~~~, to the end of the body when left open), inline code on one
# line, and HTML comments (`<!-- … -->`, across lines). An issue linked by hand in the PR's
# Development sidebar, or by a commit message, is not seen, and a PR's base branch is not
# checked (GitHub links keywords only on a PR into the default branch).
#
# Prints one tab-separated line per PR:
#   <number> <state> <draft> <head branch> <closes> <title>
# state is open, closed, or merged; draft is true or false; closes lists the issues in body
# order, each once, comma-separated: `N` for an issue in OWNER/NAME, `owner/name#N` (lowercased)
# for one in another repo, or `-` for none. The title comes last, its tabs turned into spaces.
# --pr reads one PR. --state lists every PR in that state, oldest first, every page read; with
# --limit N (1-100), only the N most recently updated, newest first, from one page.
# Exit codes: 0 printed (a list may be empty), 1 a gh error (gh's message on stderr),
# 2 bad arguments.
set -uo pipefail

REPO="" PR="" STATE="" LIMIT=""
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --pr) need_value "$@"; PR="$2"; shift 2 ;;
    --state) need_value "$@"; STATE="$2"; shift 2 ;;
    --limit) need_value "$@"; LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

usage() {
  echo "Usage: octo-pr-closes.sh --repo OWNER/NAME (--pr N | --state open|closed|all [--limit N])" >&2
  exit 2
}
[ -n "$REPO" ] || usage
case "$REPO" in
  */*/* | /* | */ | *[!A-Za-z0-9._/-]*) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
  */*) ;;
  *) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
esac
if [ -n "$PR" ]; then
  [ -z "$STATE" ] && [ -z "$LIMIT" ] || usage
  case "$PR" in
    '' | 0* | *[!0-9]*) echo "--pr must be a PR number" >&2; exit 2 ;;
  esac
else
  case "$STATE" in
    open | closed | all) ;;
    *) usage ;;
  esac
  case "$LIMIT" in
    '') ;;
    0* | *[!0-9]*) echo "--limit must be 1-100" >&2; exit 2 ;;
    *) [ "$LIMIT" -le 100 ] || { echo "--limit must be 1-100" >&2; exit 2; } ;;
  esac
fi

# Per PR: a `P<TAB><number><TAB><state><TAB><draft><TAB><head><TAB><title>` line, then a
# `B<TAB><line>` line for each line of its body. --jq runs once per page, so this streams.
FILTER='"P\t\(.number)\t\(if .merged_at then "merged" else .state end)\t\(.draft // false)\t\(.head.ref)\t\(.title // "" | gsub("[\\r\\n\\t]"; " "))",
  ((.body // "") | split("\n")[] | "B\t\(.)")'
if [ -n "$PR" ]; then
  OUT=$(gh api "repos/$REPO/pulls/$PR" --jq "$FILTER") || {
    echo "octo-pr-closes: could not read PR #$PR in $REPO" >&2; exit 1; }
elif [ -n "$LIMIT" ]; then
  OUT=$(gh api "repos/$REPO/pulls?state=$STATE&sort=updated&direction=desc&per_page=$LIMIT" \
    --jq ".[] | $FILTER") || {
    echo "octo-pr-closes: could not list the $STATE PRs of $REPO" >&2; exit 1; }
else
  OUT=$(gh api "repos/$REPO/pulls?state=$STATE&sort=created&direction=asc&per_page=100" \
    --paginate --jq ".[] | $FILTER") || {
    echo "octo-pr-closes: could not list the $STATE PRs of $REPO" >&2; exit 1; }
fi
[ -n "$OUT" ] || exit 0

printf '%s\n' "$OUT" | awk -v repo="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" '
  BEGIN { FS = "\t"; have = 0 }
  # strip(s): s without inline code and HTML comments; incomment carries a comment across lines.
  function strip(s,    out, n, run, rest, t, off, k) {
    out = ""
    while (s != "") {
      if (incomment) {
        k = index(s, "-->")
        if (!k) return out
        s = substr(s, k + 3); incomment = 0; out = out " "; continue
      }
      if (!match(s, /`|<!--/)) return out s
      out = out substr(s, 1, RSTART - 1)
      if (substr(s, RSTART, 1) == "<") { s = substr(s, RSTART + 4); incomment = 1; continue }
      s = substr(s, RSTART)
      match(s, /^`+/); n = RLENGTH; run = substr(s, 1, n); rest = substr(s, n + 1)
      # A code span closes at the next run of exactly as many backticks on the line.
      k = 0; off = 0; t = rest
      while (match(t, /`+/)) {
        if (RLENGTH == n) { k = off + RSTART; break }
        off += RSTART + RLENGTH - 1; t = substr(rest, off + 1)
      }
      if (k) { s = substr(rest, k + n); out = out " " } else { out = out run; s = rest }
    }
    return out
  }
  function add(ref) {
    if (index(" " seen " ", " " ref " ")) return
    seen = seen " " ref; closes = closes (closes == "" ? "" : ",") ref
  }
  function refs(s,    t, m, after, ref, own, n) {
    t = tolower(s)
    while (match(t, /(^|[^a-z0-9_])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[ \t]+(https?:\/\/github\.com\/[a-z0-9._-]+\/[a-z0-9._-]+\/issues\/[0-9]+|([a-z0-9._-]+\/[a-z0-9._-]+)?#[0-9]+)/)) {
      m = substr(t, RSTART, RLENGTH); after = substr(t, RSTART + RLENGTH, 1)
      t = substr(t, RSTART + RLENGTH)
      if (after ~ /[a-z_]/) continue
      ref = m; sub(/^.*[ \t]/, "", ref)
      if (ref ~ /^http/) {
        sub(/^https?:\/\/github\.com\//, "", ref)
        n = ref; sub(/^.*\//, "", n)
        own = ref; sub(/\/issues\/[0-9]+$/, "", own)
      } else {
        n = ref; sub(/^.*#/, "", n)
        own = ref; sub(/#[0-9]+$/, "", own)
      }
      n += 0
      if (n < 1) continue
      add(own == "" || own == repo ? n : own "#" n)
    }
  }
  function flush() {
    if (have) print meta "\t" (closes == "" ? "-" : closes) "\t" title
    closes = ""; seen = ""; incomment = 0; fence = ""
  }
  /^P\t/ {
    flush(); have = 1
    meta = $2 "\t" $3 "\t" $4 "\t" $5
    title = substr($0, length($1 $2 $3 $4 $5) + 6)
    next
  }
  /^B\t/ {
    line = substr($0, 3); sub(/\r$/, "", line)
    if (!incomment) {
      # A fence opens with 3 or more ` or ~, after any indent or quote marker, and closes
      # with a line of only the same character, at least as many.
      f = line; sub(/^[ \t>]*/, "", f)
      if (fence != "") {
        if (substr(f, 1, length(fence)) == fence) {
          r = f; gsub(substr(fence, 1, 1), "", r)
          if (r ~ /^[ \t]*$/) fence = ""
        }
        next
      }
      # A backtick fence never has a backtick after it (```code``` is inline code).
      if (match(f, /^(```+|~~~+)/) && !(substr(f, 1, 1) == "`" && index(substr(f, RLENGTH + 1), "`"))) {
        fence = substr(f, 1, RLENGTH); next
      }
    }
    refs(strip(line))
  }
  END { flush() }
'
