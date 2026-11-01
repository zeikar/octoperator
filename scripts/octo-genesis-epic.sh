#!/usr/bin/env bash
# octo-genesis-epic.sh — find the MVP epic an earlier `genesis --approve` planned, so a re-run
# plans no second one.
#
# Usage:
#   octo-genesis-epic.sh DIR
#
# DIR is the genesis folder. The helper reads GENESIS.md's repo and sentence
# (`octo-genesis-check.sh --values DIR`, which checks the proposal first), lists the repo's open
# issues labeled `epic` (`gh issue list`, at most 500), and looks for the sentence in each body.
# The match is exact, case included, except that runs of whitespace and line breaks count as one
# space and a Markdown `>` quote marker at the start of a line is ignored: a body that quotes the
# sentence in a `> ` block, wrapped or not, matches.
#
# It prints one line: `epic: <N>`, the lowest-numbered open epic that quotes the sentence, or
# `epic: none`.
#
# Read-only: its one gh call is that list; it writes nothing.
#
# Exit codes: 0 the line printed, 1 the proposal check's `FAIL: <problem>` lines, 2 bad arguments
# or DIR is not a directory, 3 gh failed (gh's output on stderr).
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$DIR" ] || { echo "Only one DIR may be given" >&2; exit 2; }
       DIR="$1"; shift ;;
  esac
done
[ -n "$DIR" ] || { echo "Usage: octo-genesis-epic.sh DIR" >&2; exit 2; }

LIMIT=500

rc=0
values="$(bash "$HERE/octo-genesis-check.sh" --values "$DIR")" || rc=$?
case "$rc" in
  0) ;;
  1) printf '%s\n' "$values"; exit 1 ;;
  *) exit 2 ;;
esac
value() { printf '%s\n' "$values" | sed -n "s/^$1: //p"; }
REPO="$(value repo)"
# Whitespace squeezed as the jq filter below squeezes each body.
WANT="$(value sentence | tr '\t\n\r\f\v' '     ' | tr -s ' ')"
WANT="${WANT# }" WANT="${WANT% }"

# One line per epic: its number, a space, then its body on one line: a newline and any `>` quote
# markers after it become one space, then every whitespace run one space. The escapes are jq's
# string escapes, so each regex holds the characters themselves: gh's gojq (Go regexp) and jq
# (Oniguruma, which reads `\v` as `v`) then agree.
FILTER='.[] | "\(.number) " + ("\n" + (.body // "") | gsub("\r"; "")
  | gsub("\n[ \t]*(>[ \t]*)*"; " ") | gsub("[ \t\n\r\f\u000b]+"; " "))'
out="$(gh issue list --repo "$REPO" --label epic --state open --limit "$LIMIT" \
  --json number,body --jq "$FILTER")" || { echo "gh issue list failed" >&2; exit 3; }

found=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n="${line%% *}" body="${line#* }"
  case "$n" in '' | *[!0-9]*) echo "Unexpected gh output: $line" >&2; exit 3 ;; esac
  [[ "$body" == *"$WANT"* ]] || continue
  if [ -z "$found" ] || [ "$n" -lt "$found" ]; then found="$n"; fi
done <<EOF
$out
EOF
echo "epic: ${found:-none}"
