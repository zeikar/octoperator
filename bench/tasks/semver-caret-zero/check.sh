#!/usr/bin/env bash
# check.sh — hidden oracle for bench task semver-caret-zero.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when `python3 semver.py RANGE` in REPO_DIR prints the stdin versions that satisfy RANGE,
# in input order, with npm's caret rule (the leftmost non-zero part stays fixed: ^1.2.3 <2.0.0,
# ^0.2.3 <0.3.0, ^0.0.3 <0.0.4, ^0.0.0 only 0.0.0, also with two-digit parts), while exact
# versions, comparisons, ~, and space-separated ranges (a caret range among them) work as before;
# README.md's Comparator | Matches table has a `^0.2.3` row whose Matches cell holds >=0.2.3 and
# <0.3.0, and a `^0.0.3` row with >=0.0.3 and <0.0.4 (backticks and spacing are free); and
# `make test` passes. Exits 0 on pass, 1 on fail, 2 on bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: check.sh REPO_DIR" >&2; exit 2 ;;
esac
repo="$1"
[ -f "$repo/semver.py" ] || { echo "FAIL: $repo/semver.py not found"; exit 1; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PYTHONDONTWRITEBYTECODE=1

failed=0
fail() { failed=1; echo "FAIL: $1"; }

# matches <range> <versions> <expected> : versions and expected are space-separated.
matches() {
  got="$(printf '%s\n' $2 | (cd "$repo" && python3 semver.py "$1") 2>"$tmp/err")" || {
    fail "'$1': exit $? ($(cat "$tmp/err"))"; return; }
  got="$(printf '%s' "$got" | tr '\n' ' ')"
  [ "$got" = "$3" ] || fail "'$1' on [$2]: wanted [$3], got [$got]"
}
matches '^0.2.3' '0.2.2 0.2.3 0.2.10 0.3.0 0.9.0 1.0.0' '0.2.3 0.2.10'
matches '^0.10.1' '0.9.9 0.10.1 0.10.12 0.11.0' '0.10.1 0.10.12'
matches '^0.0.3' '0.0.2 0.0.3 0.0.4 0.1.0 1.0.0' '0.0.3'
matches '^0.0.12' '0.0.11 0.0.12 0.0.13' '0.0.12'
matches '^0.0.0' '0.0.0 0.0.1 0.1.0' '0.0.0'
matches '^0.1.0' '0.0.9 0.1.0 0.1.7 0.2.0' '0.1.0 0.1.7'
matches '^1.2.3' '1.2.2 1.2.3 1.10.0 2.0.0' '1.2.3 1.10.0'
matches '^10.0.1' '10.0.0 10.0.1 10.5.0 11.0.0' '10.0.1 10.5.0'
matches '^1.0.0' '0.9.9 1.0.0 1.99.99 2.0.0' '1.0.0 1.99.99'
matches '~0.2.3' '0.2.2 0.2.3 0.2.9 0.3.0' '0.2.3 0.2.9'
matches '~1.2.3' '1.2.3 1.2.9 1.3.0' '1.2.3 1.2.9'
matches '0.2.3' '0.2.2 0.2.3 0.2.4' '0.2.3'
matches '>=0.2.0 <0.4.0' '0.1.9 0.2.0 0.3.9 0.4.0' '0.2.0 0.3.9'
matches '>0.0.1 <=0.0.3' '0.0.1 0.0.2 0.0.3 0.0.4' '0.0.2 0.0.3'
matches '^0.2.3 <0.2.5' '0.2.3 0.2.4 0.2.5 0.3.0' '0.2.3 0.2.4'
matches '^0.2.3' '0.2.9 0.2.3 0.3.0 0.2.4' '0.2.9 0.2.3 0.2.4'

# The README table rows. (Not inside $(…): bash 3.2 misparses a here-doc with quotes inside a
# command substitution.)
python3 - "$repo/README.md" >"$tmp/readme" <<'PY2' || fail "README check crashed"
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        lines = fh.read().splitlines()
except OSError as err:
    print(f"FAIL: cannot read README.md: {err}")
    sys.exit()


def cells(row):
    row = row.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|"):
        row = row[:-1]
    return [re.sub(r"[`*]", "", c).strip() for c in row.split("|")]


DELIMITER = re.compile(r"\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")
rows = None
for i in range(len(lines) - 1):
    if "|" in lines[i] and DELIMITER.match(lines[i + 1]) \
            and [c.lower() for c in cells(lines[i])][:2] == ["comparator", "matches"]:
        rows = []
        for line in lines[i + 2:]:
            if "|" not in line or not line.strip():
                break
            rows.append(cells(line))
        break
if rows is None:
    print("FAIL: README.md has no Comparator | Matches table")
    sys.exit()
for comparator, bounds in (("^0.2.3", (">=0.2.3", "<0.3.0")), ("^0.0.3", (">=0.0.3", "<0.0.4"))):
    found = [r for r in rows if r[0] == comparator]
    matches = re.sub(r"\s+", "", found[0][1]) if found and len(found[0]) > 1 else ""
    if not found:
        print(f"FAIL: the README's comparator table has no {comparator} row")
    elif not all(b in matches for b in bounds):
        print(f"FAIL: the README's {comparator} row gives {found[0][1]!r}, "
              f"wanted {' '.join(bounds)}")
PY2
[ -s "$tmp/readme" ] && { failed=1; cat "$tmp/readme"; }

(cd "$repo" && make test) >"$tmp/test.log" 2>&1 || {
  fail "make test failed:"; tail -n 20 "$tmp/test.log"; }

[ "$failed" -eq 0 ] && echo "PASS: semver-caret-zero"
[ "$failed" -eq 0 ]
