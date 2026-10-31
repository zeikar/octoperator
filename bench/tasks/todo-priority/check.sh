#!/usr/bin/env bash
# check.sh — hidden oracle for bench task todo-priority.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when todo.py in REPO_DIR takes `add --priority high|normal|low` (default normal, still
# printing `added <id>`), rejects an unknown priority with a non-zero exit, a stderr message, and
# no new item; `list` orders high, normal, low, then by id (done items included), marks high and
# low lines with a ` (high)` / ` (low)` suffix and leaves normal lines as they were; a list file
# in the seed's format (no priorities) still loads as all normal; README.md mentions --priority;
# and `make test` passes. Runs with TODO_FILE in a temp dir, from a temp working directory.
# Exits 0 on pass, 1 on fail, 2 on bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: check.sh REPO_DIR" >&2; exit 2 ;;
esac
repo="$(cd "${1:-}" 2>/dev/null && pwd)" || { echo "FAIL: no such directory: $1"; exit 1; }
[ -f "$repo/todo.py" ] || { echo "FAIL: $repo/todo.py not found"; exit 1; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PYTHONDONTWRITEBYTECODE=1

failed=0
fail() { failed=1; echo "FAIL: $1"; }

# todo <list file> <args...> : run todo.py against a list file, from the temp dir.
todo() { f="$1"; shift; (cd "$tmp" && TODO_FILE="$f" python3 "$repo/todo.py" "$@"); }
oneline() { printf '%s' "$1" | tr '\n' '|'; }
# says <label> <expected stdout> <list file> <args...> : exits 0 and prints <expected>.
says() {
  label="$1"; want="$2"; f="$3"; shift 3
  got="$(todo "$f" "$@" 2>"$tmp/err")" || { fail "$label: exit $? ($(cat "$tmp/err"))"; return; }
  [ "$got" = "$want" ] || fail "$label: wanted [$(oneline "$want")], got [$(oneline "$got")]"
}

new="$tmp/new.json"
says "add without --priority" "added 1" "$new" add pay rent
says "add --priority high" "added 2" "$new" add --priority high fix the roof
says "add --priority low" "added 3" "$new" add --priority low sort photos
says "add, second normal item" "added 4" "$new" add call mom
says "add --priority normal" "added 5" "$new" add --priority normal buy milk
order="$(printf '%s\n' '2 [ ] fix the roof (high)' '1 [ ] pay rent' '4 [ ] call mom' \
  '5 [ ] buy milk' '3 [ ] sort photos (low)')"
says "list: high, normal, low, then by id" "$order" "$new" list
says "done 3" "" "$new" "done" 3
says "done 2" "" "$new" "done" 2
done_order="$(printf '%s\n' '2 [x] fix the roof (high)' '1 [ ] pay rent' '4 [ ] call mom' \
  '5 [ ] buy milk' '3 [x] sort photos (low)')"
says "list: done items keep their place" "$done_order" "$new" list

out="$(todo "$new" add --priority urgent today 2>"$tmp/err")"
rc=$?
[ "$rc" -ne 0 ] || fail "add --priority urgent: wanted a non-zero exit, got 0"
[ -s "$tmp/err" ] || fail "add --priority urgent: wanted an error on stderr"
[ -z "$out" ] || fail "add --priority urgent: wanted nothing on stdout, got: $out"
says "list after a rejected add" "$done_order" "$new" list

# A list saved by the seed: items without a priority.
old="$tmp/old.json"
printf '%s\n' '{"next_id": 3, "items": [{"id": 1, "text": "old one", "done": false},' \
  '{"id": 2, "text": "old two", "done": true}]}' >"$old"
says "list, a list saved before priorities" "$(printf '1 [ ] old one\n2 [x] old two')" "$old" list
says "add --priority high to an old list" "added 3" "$old" add --priority high new one
says "list, an old list plus a high item" \
  "$(printf '3 [ ] new one (high)\n1 [ ] old one\n2 [x] old two')" "$old" list

grep -Fq -- '--priority' "$repo/README.md" 2>/dev/null || fail "README.md does not mention --priority"

(cd "$repo" && make test) >"$tmp/test.log" 2>&1 || {
  fail "make test failed:"; tail -n 20 "$tmp/test.log"; }

[ "$failed" -eq 0 ] && echo "PASS: todo-priority"
[ "$failed" -eq 0 ]
