#!/usr/bin/env bash
# check.sh — hidden oracle for bench task vsort-numeric.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when `python3 vsort.py` in REPO_DIR sorts versions part by part as numbers (1.9.0 before
# 1.10.0, 2.0.0 before 10.0.0, 1.2 before 1.2.1), still skips blank lines, and `make test` passes.
# Exits 0 on pass, 1 on fail, 2 on bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: check.sh REPO_DIR" >&2; exit 2 ;;
esac
repo="$1"
[ -f "$repo/vsort.py" ] || { echo "FAIL: $repo/vsort.py not found"; exit 1; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PYTHONDONTWRITEBYTECODE=1

failed=0
fail() { failed=1; echo "FAIL: $1"; }

# sorts <label> <input> <expected> : input and expected are newline-separated versions.
sorts() {
  got="$(printf '%s\n' "$2" | (cd "$repo" && python3 vsort.py) 2>"$tmp/err")" || {
    fail "$1: exit $? ($(cat "$tmp/err"))"; return; }
  [ "$got" = "$3" ] || fail "$1: wanted [$(oneline "$3")], got [$(oneline "$got")]"
}
oneline() { printf '%s' "$1" | tr '\n' ' '; }

sorts "two-digit minor" "$(printf '1.10.0\n1.9.0\n1.2.0')" "$(printf '1.2.0\n1.9.0\n1.10.0')"
sorts "two-digit major" "$(printf '10.0.0\n2.0.0\n1.0.0')" "$(printf '1.0.0\n2.0.0\n10.0.0')"
sorts "two-digit patch" "$(printf '0.1.10\n0.1.9\n0.1.11')" "$(printf '0.1.9\n0.1.10\n0.1.11')"
sorts "prefix first" "$(printf '1.2.1\n1.2\n0.9')" "$(printf '0.9\n1.2\n1.2.1')"
sorts "blank lines skipped" "$(printf '1.10\n\n1.9\n')" "$(printf '1.9\n1.10')"

(cd "$repo" && make test) >"$tmp/test.log" 2>&1 || {
  fail "make test failed:"; tail -n 20 "$tmp/test.log"; }

[ "$failed" -eq 0 ] && echo "PASS: vsort-numeric"
[ "$failed" -eq 0 ]
