#!/usr/bin/env bash
# check.sh — hidden oracle for bench task csvcut-docs.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when REPO_DIR's README.md has a `## Supported input` section (any heading level from 2
# on, any case) holding a Markdown table with the columns Feature | Supported (or Feature |
# Supported | Notes) and exactly six rows, one per feature the issue lists, told apart by
# keywords in the Feature cell. Each Supported cell must be yes or no (any case; backticks, bold,
# a trailing period, and outer pipes are optional) and match what the seed's csvcut.py does:
#   yes: select by header name, a -d delimiter, CRLF line endings
#   no:  select by position, quoted fields holding the delimiter, quoted fields holding a line
#        break (csvcut splits each line on the delimiter, whatever its docstring says)
# Then csvcut.py must behave as before on those features, and `make test` must pass.
# Exits 0 on pass, 1 on fail, 2 on bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: check.sh REPO_DIR" >&2; exit 2 ;;
esac
repo="$1"
[ -f "$repo/csvcut.py" ] || { echo "FAIL: $repo/csvcut.py not found"; exit 1; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PYTHONDONTWRITEBYTECODE=1

failed=0
fail() { failed=1; echo "FAIL: $1"; }

# The README table: one FAIL line per problem. (Not inside $(…): bash 3.2 misparses a here-doc
# with quotes inside a command substitution.)
python3 - "$repo/README.md" >"$tmp/facts" <<'PY' || fail "README check crashed"
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        lines = fh.read().splitlines()
except OSError as err:
    print(f"FAIL: cannot read README.md: {err}")
    sys.exit()

HEADING = re.compile(r" {0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r" {0,3}(```|~~~)")


def prose(block):
    """block's lines minus fenced and indented code blocks."""
    out, fenced, code = [], False, False
    for i, line in enumerate(block):
        if FENCE.match(line):
            fenced = not fenced
            continue
        blank_before = i == 0 or not block[i - 1].strip()
        code = re.match(r"( {4}|\t)", line) is not None and (blank_before or code)
        if not fenced and not code:
            out.append(line)
    return out


def section(title):
    """The lines under the first heading (level 2 or deeper) named title, up to the next heading
    of the same or a higher level; None when there is no such heading."""
    fenced, level, body = False, None, None
    for line in lines:
        if FENCE.match(line):
            fenced = not fenced
        m = None if fenced else HEADING.match(line)
        if level is None:
            if m and len(m.group(1)) >= 2 and m.group(2).lower() == title.lower():
                level, body = len(m.group(1)), []
            continue
        if m and len(m.group(1)) <= level:
            break
        body.append(line)
    return body


def cells(row):
    row = row.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|"):
        row = row[:-1]
    return [re.sub(r"[`*]", "", c).strip() for c in row.split("|")]


DELIMITER = re.compile(r"\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")


def table(block, headers):
    """The body rows of the first table in block whose columns are one of headers, or None."""
    block = prose(block)
    for i in range(len(block) - 1):
        if "|" in block[i] and DELIMITER.match(block[i + 1]) \
                and [c.lower() for c in cells(block[i])] in headers:
            rows = []
            for line in block[i + 2:]:
                if "|" not in line or not line.strip():
                    break
                rows.append(cells(line))
            return rows
    return None


# Which feature a row is about, from keywords in its Feature cell, tried in this order: line
# endings before line breaks, both before "quoted" (two features are quoted fields), and that
# before "delimiter" (the quoted-delimiter row names the delimiter too).
FEATURES = [
    ("crlf", re.compile(r"crlf|windows|line[- ]endings?|carriage|\\r\\n", re.I)),
    ("linebreak", re.compile(r"line[- ]?breaks?|newlines?|multi[- ]?line|span", re.I)),
    ("quoted", re.compile(r"quot", re.I)),
    ("position", re.compile(r"position|number|index", re.I)),
    ("delimiter", re.compile(r"delimiter|separator|-d\b", re.I)),
    ("name", re.compile(r"\bnames?\b", re.I)),
]
# Each feature's label and the answer the seed's code gives.
WANTED = {
    "name": ("select columns by header name", "yes"),
    "position": ("select columns by position", "no"),
    "delimiter": ("a delimiter other than a comma", "yes"),
    "quoted": ("quoted fields that contain the delimiter", "no"),
    "linebreak": ("quoted fields that contain a line break", "no"),
    "crlf": ("Windows (CRLF) line endings", "yes"),
}


def feature_of(row):
    return next((name for name, pattern in FEATURES if pattern.search(row[0])), None)


supported = section("Supported input")
if supported is None:
    print("FAIL: README.md has no ## Supported input section")
    sys.exit()
rows = table(supported, [["feature", "supported"], ["feature", "supported", "notes"]])
if rows is None:
    print("FAIL: the Supported input section has no Feature | Supported table")
    sys.exit()
if len(rows) != len(WANTED):
    print(f"FAIL: the Supported input table has {len(rows)} rows, wanted exactly {len(WANTED)}")
for row in rows:
    if feature_of(row) is None:
        print(f"FAIL: the Supported input table has a row for none of the features: {row[0]!r}")
for feature, (label, want) in WANTED.items():
    found = [r for r in rows if feature_of(r) == feature]
    if not found:
        print(f"FAIL: the Supported input table has no row for: {label}")
        continue
    if len(found) > 1:
        print(f"FAIL: the Supported input table has more than one row for: {label}")
        continue
    got = found[0][1] if len(found[0]) > 1 else ""
    answer = got.rstrip(".").strip().lower()
    if answer not in ("yes", "no"):
        print(f"FAIL: the Supported cell for {label} is {got!r}, wanted yes or no")
    elif answer != want:
        print(f"FAIL: the Supported input table says {answer} for {label}; csvcut.py says {want}")
PY
[ -s "$tmp/facts" ] && { failed=1; cat "$tmp/facts"; }

# Behavior: the documented features work as in the seed, and quoted fields are still not parsed.
# cuts <label> <printf format of the input> <expected output> <csvcut args...>
cuts() {
  label="$1"; input="$2"; want="$3"; shift 3
  # shellcheck disable=SC2059  # the format is the input
  printf "$input" >"$tmp/in.csv"
  got="$(cd "$repo" && python3 csvcut.py "$@" "$tmp/in.csv" 2>"$tmp/err")" || {
    fail "csvcut.py $*: exit $? ($(cat "$tmp/err"))"; return; }
  [ "$got" = "$want" ] \
    || fail "csvcut.py, $label: wanted [$(oneline "$want")], got [$(oneline "$got")]"
}
oneline() { printf '%s' "$1" | od -An -c | tr -s ' \n' ' '; }
cuts "by name, in the order asked" 'id,name,city\n1,Ada,London\n' \
  "$(printf 'city,id\nLondon,1')" -f city,id
cuts "-d ';'" 'id;name\n1;Ada\n' "$(printf 'name\nAda')" -d ';' -f name
cuts "CRLF line endings" 'id,name\r\n1,Ada\r\n' "$(printf 'name\nAda')" -f name
cuts "a quoted field holding the delimiter (still split on it)" 'name,city\n"Smith, J",Oslo\n' \
  "$(printf 'city\n J"')" -f city
printf 'id,name\n1,Ada\n' >"$tmp/in.csv"
(cd "$repo" && python3 csvcut.py -f 2 "$tmp/in.csv") >"$tmp/out" 2>&1 \
  && fail "csvcut.py -f 2: wanted a non-zero exit (no column is named 2), got 0"

(cd "$repo" && make test) >"$tmp/test.log" 2>&1 || {
  fail "make test failed:"; tail -n 20 "$tmp/test.log"; }

[ "$failed" -eq 0 ] && echo "PASS: csvcut-docs"
[ "$failed" -eq 0 ]
