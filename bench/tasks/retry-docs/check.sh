#!/usr/bin/env bash
# check.sh — hidden oracle for bench task retry-docs.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when REPO_DIR's README.md documents retry.sh's settings and exit status, and the script
# still behaves as documented. Wording is free, so the README facts are matched loosely:
#   - RETRY_ATTEMPTS with its default 5, and RETRY_DELAY with its default 2: the default on the
#     line naming the variable or one of the next 5, stopping before a line naming the other one
#   - a line about the exit status with "last", "final", or "latest" within 2 lines of it
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


def near(pattern, flags, start, end):
    return any(re.search(pattern, line, flags) for line in lines[max(start, 0):end])


def scope(i, other):
    """Line i and up to 5 more, ending before a line that names the other variable."""
    end = i + 1
    while end < min(i + 6, len(lines)) and other not in lines[end]:
        end += 1
    return end


settings = {"RETRY_ATTEMPTS": "5", "RETRY_DELAY": "2"}
for var, default in settings.items():
    other = next(name for name in settings if name != var)
    named = [i for i, line in enumerate(lines) if var in line]
    if not named:
        print(f"FAIL: README.md does not mention {var}")
    # The default as a whole number: not part of a word or of a decimal like 2.5 (a full stop
    # after it is fine).
    number = rf"(?<!\w)(?<!\d\.){default}(?!\w)(?!\.\d)"
    if named and not any(near(number, 0, i, scope(i, other)) for i in named):
        print(f"FAIL: README.md does not give {var}'s default ({default}) next to it")

exit_lines = [i for i, line in enumerate(lines) if re.search(r"\bexit", line, re.I)]
if not any(near(r"\b(last|final|latest)\b", re.I, i - 2, i + 3) for i in exit_lines):
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
