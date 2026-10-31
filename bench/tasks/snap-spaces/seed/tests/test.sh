#!/usr/bin/env bash
# Tests for snap.sh. Run with: make test
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SNAP="$HERE/../snap.sh"
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: wanted $3, got $2"; failed=1; fi
}
# listing <dir> : the names in <dir>, sorted, on one line.
listing() { (cd "$1" && ls -A | LC_ALL=C sort | tr '\n' ' '); }

mkdir -p "$tmp/src/sub.conf" "$tmp/src/nested"
echo "port=1" >"$tmp/src/app.conf"
echo "port=2" >"$tmp/src/db.conf"
echo "notes" >"$tmp/src/notes.txt"
echo "nested" >"$tmp/src/nested/deep.conf"

bash "$SNAP" "$tmp/src" "$tmp/out"
check "copies the .conf files" "$?" 0
check "only *.conf files directly in SRC, as .bak" "$(listing "$tmp/out")" "app.conf.bak db.conf.bak "
check "keeps the content" "$(cat "$tmp/out/app.conf.bak")" "port=1"

mkdir -p "$tmp/empty"
echo "notes" >"$tmp/empty/notes.txt"
bash "$SNAP" "$tmp/empty" "$tmp/out2"
check "no .conf files exits 0" "$?" 0
check "no .conf files copies nothing" "$(listing "$tmp/out2")" ""

bash "$SNAP" "$tmp/src" 2>/dev/null
check "one argument is a usage error" "$?" 2

exit "$failed"
