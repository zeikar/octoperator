#!/usr/bin/env bash
# check.sh — hidden oracle for bench task mdtable-rename-flag.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when mdtable.py in REPO_DIR takes --delimiter and -d (default still a comma), still takes
# --sep with the same output, exit 0, and a stderr warning that contains "deprecated" and names
# --delimiter, and prints nothing on stderr without --sep; --help shows --delimiter; README.md
# mentions --delimiter, and every paragraph or code block in it that mentions --sep also says it
# is deprecated; CHANGELOG.md's [Unreleased] section has an `### Added` list item naming
# --delimiter and a `### Deprecated` list item naming --sep; and `make test` passes. The wording
# of the warning and the entries is not judged. Exits 0 on pass, 1 on fail, 2 on bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: check.sh REPO_DIR" >&2; exit 2 ;;
esac
repo="$1"
[ -f "$repo/mdtable.py" ] || { echo "FAIL: $repo/mdtable.py not found"; exit 1; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PYTHONDONTWRITEBYTECODE=1

failed=0
fail() { failed=1; echo "FAIL: $1"; }

printf 'name;shell\nada;/bin/zsh\nlinus;/bin/bash\n' >"$tmp/semi.txt"
printf 'name,shell\nada,/bin/zsh\n' >"$tmp/comma.txt"
semi="$(printf '| name | shell |\n|---|---|\n| ada | /bin/zsh |\n| linus | /bin/bash |')"
comma="$(printf '| name | shell |\n|---|---|\n| ada | /bin/zsh |')"
mdtable() { (cd "$repo" && python3 mdtable.py "$@"); }

# prints <label> <expected> <file> [args...] : exits 0, prints <expected>, and nothing on stderr.
prints() {
  label="$1"; want="$2"; file="$3"; shift 3
  out="$(mdtable "$@" "$file" 2>"$tmp/err")" || { fail "$label: exit $? ($(cat "$tmp/err"))"; return; }
  [ "$out" = "$want" ] || fail "$label: got: $out"
  [ ! -s "$tmp/err" ] || fail "$label: wanted nothing on stderr, got: $(cat "$tmp/err")"
}
prints "no option: commas" "$comma" "$tmp/comma.txt"
prints "--delimiter ';'" "$semi" "$tmp/semi.txt" --delimiter ';'
prints "-d ';'" "$semi" "$tmp/semi.txt" -d ';'

out="$(mdtable --sep ';' "$tmp/semi.txt" 2>"$tmp/err")"
rc=$?
[ "$rc" -eq 0 ] || fail "--sep ';': wanted exit 0, got $rc ($(cat "$tmp/err"))"
[ "$out" = "$semi" ] || fail "--sep ';': wanted the same table as --delimiter ';', got: $out"
grep -qi 'deprecated' "$tmp/err" \
  || fail "--sep: wanted a stderr warning saying it is deprecated, got: $(cat "$tmp/err")"
grep -Fq -- '--delimiter' "$tmp/err" \
  || fail "--sep: wanted the stderr warning to name --delimiter, got: $(cat "$tmp/err")"

mdtable --help >"$tmp/help" 2>&1 || fail "--help exits non-zero"
grep -Fq -- '--delimiter' "$tmp/help" || fail "--help does not show --delimiter"

# The README and CHANGELOG structure: one FAIL line per problem. (Not inside $(…): bash 3.2
# misparses a here-doc with quotes inside a command substitution.)
python3 - "$repo" >"$tmp/docs" <<'PY' || fail "docs check crashed"
import os
import re
import sys


def read(name):
    try:
        with open(os.path.join(sys.argv[1], name), encoding="utf-8") as fh:
            return fh.read().splitlines()
    except OSError as err:
        print(f"FAIL: cannot read {name}: {err}")
        return None


readme = read("README.md")
if readme is not None:
    if not any("--delimiter" in line for line in readme):
        print("FAIL: README.md does not mention --delimiter")
    # Paragraphs and code blocks: runs of non-blank lines.
    blocks, block = [], []
    for line in readme + [""]:
        if line.strip():
            block.append(line)
        elif block:
            blocks.append(block)
            block = []
    for block in blocks:
        text = "\n".join(block)
        if re.search(r"--sep\b", text) and not re.search(r"deprecat", text, re.I):
            first = next(line for line in block if re.search(r"--sep\b", line))
            print(f"FAIL: README.md mentions --sep without calling it deprecated: {first.strip()}")

HEADING = re.compile(r"(#{1,6})\s+(.*?)\s*#*\s*$")


def subsection(lines, level, title):
    """The lines under the first heading of exactly this level whose text matches title (a
    regex), up to the next heading of the same or a higher level; None when there is none."""
    body = None
    for line in lines:
        m = HEADING.match(line)
        if body is None:
            if m and len(m.group(1)) == level and re.fullmatch(title, m.group(2), re.I):
                body = []
            continue
        if m and len(m.group(1)) <= level:
            break
        body.append(line)
    return body


def items(lines):
    """The list items in lines, each with its indented continuation lines joined on."""
    out, open_item = [], False
    for line in lines:
        if re.match(r"\s{0,3}[-*+]\s", line):
            out.append(line)
            open_item = True
        elif open_item and line.strip() and line[:1].isspace():
            out[-1] += " " + line.strip()
        else:
            open_item = False
    return out


changelog = read("CHANGELOG.md")
if changelog is not None:
    unreleased = subsection(changelog, 2, r"\[?unreleased\]?")
    if unreleased is None:
        print("FAIL: CHANGELOG.md has no ## [Unreleased] section")
    else:
        for title, flag in (("Added", "--delimiter"), ("Deprecated", "--sep")):
            sub = subsection(unreleased, 3, title)
            if sub is None:
                print(f"FAIL: CHANGELOG.md's [Unreleased] section has no ### {title} subsection")
            elif not any(re.search(re.escape(flag) + r"\b", i) for i in items(sub)):
                print(f"FAIL: CHANGELOG.md's [Unreleased] ### {title} has no entry naming {flag}")
PY
[ -s "$tmp/docs" ] && { failed=1; cat "$tmp/docs"; }

(cd "$repo" && make test) >"$tmp/test.log" 2>&1 || {
  fail "make test failed:"; tail -n 20 "$tmp/test.log"; }

[ "$failed" -eq 0 ] && echo "PASS: mdtable-rename-flag"
[ "$failed" -eq 0 ]
