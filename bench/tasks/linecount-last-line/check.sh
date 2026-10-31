#!/usr/bin/env bash
# check.sh — hidden oracle for bench task linecount-last-line.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when `python3 linecount.py FILE...` in REPO_DIR counts a non-empty last line that has no
# trailing \n, while still counting everything else the way `wc -l` does: only \n ends a line (a
# lone \r, as progress bars write, does not; \r\n is one line ending), an empty file is 0, and
# `<count> <file>` / `<count> total` keep their format. `make test` must pass too.
# Exits 0 on pass, 1 on fail, 2 on bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: check.sh REPO_DIR" >&2; exit 2 ;;
esac
repo="$1"
[ -f "$repo/linecount.py" ] || { echo "FAIL: $repo/linecount.py not found"; exit 1; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PYTHONDONTWRITEBYTECODE=1

failed=0
fail() { failed=1; echo "FAIL: $1"; }

# counts <label> <printf format of the file> <expected count>
n=0
counts() {
  n=$((n + 1)); f="$tmp/f$n.txt"
  # shellcheck disable=SC2059  # the format is the file's content
  printf "$2" >"$f"
  got="$(cd "$repo" && python3 linecount.py "$f" 2>"$tmp/err")" || {
    fail "$1: exit $? ($(cat "$tmp/err"))"; return; }
  [ "$got" = "$3 $f" ] || fail "$1: wanted \"$3 <file>\", got \"${got/"$f"/<file>}\""
}
counts "no trailing newline" 'one\ntwo' 2
counts "a single unterminated line" 'one' 1
counts "trailing newline" 'one\ntwo\n' 2
counts "empty file" '' 0
counts "one blank line" '\n' 1
counts "blank lines, then an unterminated line" '\n\nlast' 3
counts "a lone \\r does not end a line" '10%%\r50%%\r100%%\n' 1
counts "a lone \\r, no trailing newline" '10%%\r50%%\r100%%' 1
counts "\\r then \\n, then an unterminated line" 'fetch 10%%\rfetch 100%%\ndone' 2
counts "\\r\\n line endings" 'one\r\ntwo\r\n' 2
counts "\\r\\n, no trailing newline" 'one\r\ntwo' 2

printf 'one\ntwo' >"$tmp/a.txt" && printf 'three' >"$tmp/b.txt"
got="$(cd "$repo" && python3 linecount.py "$tmp/a.txt" "$tmp/b.txt" 2>"$tmp/err")" \
  || fail "two files: exit $? ($(cat "$tmp/err"))"
want="$(printf '2 %s\n1 %s\n3 total' "$tmp/a.txt" "$tmp/b.txt")"
oneline() { printf '%s' "$1" | tr '\n' ' '; }
[ "$got" = "$want" ] || fail "two files: wanted [$(oneline "$want")], got [$(oneline "$got")]"

(cd "$repo" && make test) >"$tmp/test.log" 2>&1 || {
  fail "make test failed:"; tail -n 20 "$tmp/test.log"; }

[ "$failed" -eq 0 ] && echo "PASS: linecount-last-line"
[ "$failed" -eq 0 ]
