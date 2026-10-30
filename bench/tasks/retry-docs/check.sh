#!/usr/bin/env bash
# check.sh — hidden oracle for bench task retry-docs.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when REPO_DIR's README.md has the two sections the issue asks for, in the shape it asks:
#   - a `## Configuration` section (any heading level from 2 on, any case) holding a Markdown
#     table with the columns Variable | Default | Description and one row each for RETRY_ATTEMPTS
#     (default 5) and RETRY_DELAY (default 2, 2s, or 2 seconds), in any order; backticks, a
#     leading $, and outer pipes are optional, and the Description cells must not be empty
#   - a `## Exit status` section holding a Case | Exit status table with one row per case, told
#     apart by keywords in the Case cell: success (an attempt succeeds) gives 0, a command-less
#     call (usage) gives 2, and every attempt failing gives no fixed number but the last, final,
#     latest, or most recent attempt's status (or says retry.sh passes it through or propagates it)
# Then retry.sh must still default to 5 attempts and exit with the last attempt's status, and
# `make test` must pass. Exits 0 on pass, 1 on fail, 2 on bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: check.sh REPO_DIR" >&2; exit 2 ;;
esac
repo="$1"
[ -f "$repo/retry.sh" ] || { echo "FAIL: $repo/retry.sh not found"; exit 1; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

failed=0
fail() { failed=1; echo "FAIL: $1"; }

# The README facts: one FAIL line per missing fact. (Not inside $(…): bash 3.2 misparses a
# here-doc with quotes inside a command substitution.)
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
    return [re.sub(r"[`*]", "", c).strip().lstrip("$") for c in row.split("|")]


DELIMITER = re.compile(r"\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")


def table(block, header):
    """The body rows of the first table in block whose columns are header, or None."""
    block = prose(block)
    for i in range(len(block) - 1):
        if "|" in block[i] and DELIMITER.match(block[i + 1]) \
                and [c.lower() for c in cells(block[i])] == header:
            rows = []
            for line in block[i + 2:]:
                if "|" not in line or not line.strip():
                    break
                rows.append(cells(line))
            return rows
    return None


DEFAULTS = {
    "RETRY_ATTEMPTS": ("5", r"5(\s*(attempts?|tries))?"),
    "RETRY_DELAY": ("2", r"2(\s*(s|secs?|seconds?))?"),
}

config = section("Configuration")
if config is None:
    print("FAIL: README.md has no ## Configuration section")
else:
    rows = table(config, ["variable", "default", "description"])
    if rows is None:
        print("FAIL: the Configuration section has no Variable | Default | Description table")
    else:
        for var, (default, pattern) in DEFAULTS.items():
            found = [r for r in rows if r[0] == var]
            if not found:
                print(f"FAIL: the Configuration table has no row for {var}")
            elif len(found) > 1:
                print(f"FAIL: the Configuration table has more than one row for {var}")
            elif not re.fullmatch(pattern, found[0][1] if len(found[0]) > 1 else "", re.I):
                got = found[0][1] if len(found[0]) > 1 else ""
                print(f"FAIL: the Configuration table gives {var}'s default as {got!r}, "
                      f"wanted {default}")
            elif len(found[0]) < 3 or not found[0][2]:
                print(f"FAIL: the Configuration table has no description for {var}")


# Which case an Exit status row is about, from keywords in its Case cell. Usage first ("called
# without a command"), then failure before success ("no attempt succeeds" is a failure).
CASES = [
    ("usage", re.compile(r"\b(usage|no (command|arguments?)|without (a |any )?"
                         r"(command|arguments?))", re.I)),
    ("fail", re.compile(r"fail|\bnever\b|\bno attempt|exhaust|give(s)? up|run(s)? out", re.I)),
    ("success", re.compile(r"succe|\b0\b", re.I)),
    ("fail", re.compile(r"\battempts\b", re.I)),
]
# Each case's label, and the exit status its row must give (None: the last attempt's status).
WANTED = {"success": ("an attempt succeeds", "0"), "fail": ("every attempt fails", None),
          "usage": ("called without a command", "2")}
# The all-attempts-fail status names the last attempt, or says the command's status passes through.
LAST = re.compile(r"\b(last|final|latest|most\s+recent)\b|\bpass(es|ed|ing)?\s+(it\s+)?"
                  r"(through|along|on)\b|\bpropagat", re.I)


def case_of(row):
    return next((name for name, pattern in CASES if pattern.search(row[0])), None)


exit_status = section("Exit status")
if exit_status is None:
    print("FAIL: README.md has no ## Exit status section")
else:
    rows = table(exit_status, ["case", "exit status"])
    if rows is None:
        print("FAIL: the Exit status section has no Case | Exit status table")
    else:
        for case, (label, want) in WANTED.items():
            found = [r for r in rows if case_of(r) == case]
            status = found[0][1] if found and len(found[0]) > 1 else ""
            if not found:
                print(f"FAIL: the Exit status table has no row for: {label}")
            elif len(found) > 1:
                print(f"FAIL: the Exit status table has more than one row for: {label}")
            elif want is None and (re.search(r"\d", status) or not LAST.search(status)):
                print(f"FAIL: the Exit status table gives {status!r} when {label}, "
                      "wanted the last attempt's status")
            elif want is not None and re.findall(r"\d+", status) != [want]:
                print(f"FAIL: the Exit status table gives {status!r} when {label}, wanted {want}")
PY
[ -s "$tmp/facts" ] && { failed=1; cat "$tmp/facts"; }

# Behavior: with no RETRY_ATTEMPTS, an always-failing command runs 5 times and its status is kept.
printf '#!/usr/bin/env bash\necho x >>"%s/runs"\nexit 7\n' "$tmp" >"$tmp/always-fails"
chmod +x "$tmp/always-fails"
(cd "$repo" && RETRY_DELAY=0 bash retry.sh "$tmp/always-fails") 2>/dev/null
rc=$?
[ "$rc" -eq 7 ] || fail "retry.sh: wanted the last attempt's exit 7, got $rc"
runs="$(wc -l <"$tmp/runs" 2>/dev/null | tr -d ' ')"
[ "$runs" = 5 ] || fail "retry.sh: wanted 5 attempts by default, got ${runs:-0}"

(cd "$repo" && make test) >"$tmp/test.log" 2>&1 || {
  fail "make test failed:"; tail -n 20 "$tmp/test.log"; }

[ "$failed" -eq 0 ] && echo "PASS: retry-docs"
[ "$failed" -eq 0 ]
