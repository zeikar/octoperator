#!/usr/bin/env bash
# check.sh — hidden oracle for bench task mdtable-rename-flag.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when mdtable.py in REPO_DIR takes --delimiter and -d (default still a comma), still takes
# --sep with the same output, exit 0, and a stderr warning that contains "deprecated" and names
# --delimiter, and prints nothing on stderr without --sep; --help shows --delimiter; README.md
# mentions --delimiter, and every mention of --sep in it is framed as deprecated (its paragraph
# or code block says "deprecat", or a heading it sits under does; a heading that names --sep needs
# "deprecat" somewhere in its section); CHANGELOG.md's [Unreleased] section has an `### Added` list item naming
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


HEADING = re.compile(r"(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r" {0,3}(```|~~~)")
SEP = re.compile(r"--sep\b")
DEPRECATED = re.compile(r"deprecat", re.I)


def blocks(lines):
    """README lines as (headings, start, block) triples. A block is a heading line on its own or
    a run of non-blank lines (a fenced code block is one run, blank lines and all). start is the
    heading's line index, or None for other blocks; headings holds the text of every heading the
    block sits under (for a heading, itself and those above it)."""
    out, stack, block, fenced = [], [], [], False

    def flush():
        if block:
            out.append(([text for _, text in stack], None, list(block)))
            block.clear()

    for i, line in enumerate(lines):
        m = None if fenced else HEADING.match(line)
        if FENCE.match(line):
            fenced = not fenced
        if m:
            flush()
            level = len(m.group(1))
            stack[:] = [(lv, text) for lv, text in stack if lv < level] + [(level, m.group(2))]
            out.append(([text for _, text in stack], i, [line]))
        elif line.strip() or fenced:
            block.append(line)
        else:
            flush()
    flush()
    return out


def section_text(lines, start):
    """The text from the heading at lines[start] up to the next heading (outside a fenced code
    block) of its level or higher."""
    level = len(HEADING.match(lines[start]).group(1))
    out, fenced = [lines[start]], False
    for line in lines[start + 1:]:
        m = None if fenced else HEADING.match(line)
        if m and len(m.group(1)) <= level:
            break
        if FENCE.match(line):
            fenced = not fenced
        out.append(line)
    return "\n".join(out)


readme = read("README.md")
if readme is not None:
    if not any("--delimiter" in line for line in readme):
        print("FAIL: README.md does not mention --delimiter")
    # Every mention of --sep must be framed as deprecated: by its own paragraph or code block,
    # by a heading it sits under, or, for a heading that names --sep, by the heading's section.
    for headings, start, block in blocks(readme):
        text = "\n".join(block)
        if not SEP.search(text) or DEPRECATED.search(text) \
                or any(DEPRECATED.search(h) for h in headings):
            continue
        if start is not None and DEPRECATED.search(section_text(readme, start)):
            continue
        first = next(line for line in block if SEP.search(line))
        print(f"FAIL: README.md mentions --sep without calling it deprecated: {first.strip()}")


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
