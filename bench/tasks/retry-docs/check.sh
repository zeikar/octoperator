#!/usr/bin/env bash
# check.sh — hidden oracle for bench task retry-docs.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when REPO_DIR's README.md documents retry.sh's settings and exit status, and the script
# still behaves as documented. Wording is free, so the README facts are matched loosely:
#   - RETRY_ATTEMPTS with its default 5, and RETRY_DELAY with its default 2: the default in the
#     text after a mention of the variable (not a `VAR=` assignment), up to the end of the 5th
#     line after it or the next mention of the other variable, whichever comes first
#   - a sentence saying it exits with (or returns) the status or code of the last, final, latest,
#     or most recent attempt, in a paragraph that does not also give a fixed non-zero status for
#     a failure
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
        text = fh.read()
except OSError as err:
    print(f"FAIL: cannot read README.md: {err}")
    sys.exit()


def after_mentions(var, other):
    """The text after each mention of var that is not a `var=` assignment, up to the end of the
    5th line after it or the next mention of other, with `var=...` assignments blanked out."""
    for mention in re.finditer(rf"\b{var}\b(?!=)", text):
        rest = text[mention.end():]
        end = -1
        for _ in range(6):
            end = rest.find("\n", end + 1)
            if end < 0:
                end = len(rest)
                break
        cut = rest.find(other, 0, end)
        yield re.sub(rf"\b{var}=\S*", " ", rest[:end if cut < 0 else cut])


settings = {"RETRY_ATTEMPTS": "5", "RETRY_DELAY": "2"}
for var, default in settings.items():
    other = next(name for name in settings if name != var)
    if var not in text:
        print(f"FAIL: README.md does not mention {var}")
        continue
    # The default as a whole number: not part of a word or of a decimal like 2.5 (a full stop
    # after it is fine).
    number = rf"(?<!\w)(?<!\d\.){default}(?!\w)(?!\.\d)"
    if not any(re.search(number, scope) for scope in after_mentions(var, other)):
        print(f"FAIL: README.md does not give {var}'s default ({default}) next to it")


def sentences(paragraph):
    """A paragraph's sentences; each list item, table row, or heading starts a new one."""
    items = re.split(r"\n(?=[ \t]*(?:[-*+#|]|\d+\.)\s)", paragraph)
    for item in items:
        yield from re.split(r"(?<=[.!?])\s+", " ".join(item.split()))


def says_last_status(sentence):
    return (re.search(r"\b(exit|return)", sentence, re.I)
            and re.search(r"\b(status|code)\b", sentence, re.I)
            and re.search(r"\b(last|final|latest|most recent)\b", sentence, re.I))


# "If all attempts fail, it exits 1": a fixed status for the failure case is wrong.
FIXED_STATUS = re.compile(
    r"\b(exit|return)(s|ed)?\b(?:[\s`:]+(?:with|an?|the|exit|status|code|of))*[\s`:]+[1-9]\d*\b",
    re.I)


def fixed_failure_status(sentence):
    return re.search(r"\bfail", sentence, re.I) and FIXED_STATUS.search(sentence)


paragraphs = [list(sentences(p)) for p in re.split(r"\n[ \t]*\n", text)]
if not any(any(map(says_last_status, p)) and not any(map(fixed_failure_status, p))
           for p in paragraphs):
    print("FAIL: README.md does not say retry.sh exits with the last attempt's status")
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
