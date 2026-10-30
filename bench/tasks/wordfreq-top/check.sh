#!/usr/bin/env bash
# check.sh — hidden oracle for bench task wordfreq-top.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when wordfreq.py in REPO_DIR has a working `--top N` option: the first N lines of the
# normal output, every word when N exceeds the word count, the normal output without the option,
# a non-zero exit with nothing on stdout for a non-positive or non-integer N, the option named in
# the README, and `make test` passing. Exits 0 on pass, 1 on fail, 2 on bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: check.sh REPO_DIR" >&2; exit 2 ;;
esac
repo="$1"
[ -f "$repo/wordfreq.py" ] || { echo "FAIL: $repo/wordfreq.py not found"; exit 1; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PYTHONDONTWRITEBYTECODE=1

failed=0
fail() { failed=1; echo "FAIL: $1"; }

printf 'The cat and the dog.\nThe bird and THE cat!\n' >"$tmp/in.txt"
full="$(printf '4 the\n2 and\n2 cat\n1 bird\n1 dog')"
wordfreq() { (cd "$repo" && python3 wordfreq.py "$@"); }

# prints <label> <expected> [args...] : wordfreq.py [args...] in.txt exits 0 and prints <expected>.
prints() {
  label="$1"; want="$2"; shift 2
  out="$(wordfreq "$@" "$tmp/in.txt" 2>"$tmp/err")" || {
    fail "$label: exit $? ($(cat "$tmp/err"))"; return; }
  [ "$out" = "$want" ] || fail "$label: got: $out"
}
prints "no --top: output unchanged" "$full"
prints "--top 2: the first 2 lines" "$(printf '4 the\n2 and')" --top 2
prints "--top 1: the first line" "4 the" --top 1
prints "--top 50: every word" "$full" --top 50

for bad in 0 -1 abc; do
  out="$(wordfreq --top "$bad" "$tmp/in.txt" 2>"$tmp/err")"
  rc=$?
  [ "$rc" -ne 0 ] || fail "--top $bad: wanted a non-zero exit, got 0"
  [ -z "$out" ] || fail "--top $bad: wanted nothing on stdout, got: $out"
  [ -s "$tmp/err" ] || fail "--top $bad: wanted an error on stderr"
done

grep -Fq -- '--top' "$repo/README.md" 2>/dev/null || fail "README.md does not mention --top"

(cd "$repo" && make test) >"$tmp/test.log" 2>&1 || {
  fail "make test failed:"; tail -n 20 "$tmp/test.log"; }

[ "$failed" -eq 0 ] && echo "PASS: wordfreq-top"
[ "$failed" -eq 0 ]
