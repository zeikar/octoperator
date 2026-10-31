#!/usr/bin/env bash
# check.sh — hidden oracle for bench task snap-spaces.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when `bash snap.sh SRC DEST` in REPO_DIR copies every regular *.conf file directly in
# SRC to DEST/<name>.bak whatever its name (spaces, two spaces, quotes, `*`, a leading `-`), with
# spaces in SRC and DEST too, and nothing else (no other files, no directory named *.conf, no
# nested files), exiting 0; when a SRC without *.conf files exits 0 and creates only an empty
# DEST; when a wrong argument count exits 2; and when `make test` passes. snap.sh runs from a
# temp working directory. Exits 0 on pass, 1 on fail, 2 on bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: check.sh REPO_DIR" >&2; exit 2 ;;
esac
repo="$(cd "${1:-}" 2>/dev/null && pwd)" || { echo "FAIL: no such directory: $1"; exit 1; }
[ -f "$repo/snap.sh" ] || { echo "FAIL: $repo/snap.sh not found"; exit 1; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

failed=0
fail() { failed=1; echo "FAIL: $1"; }
snap() { (cd "$tmp" && bash "$repo/snap.sh" "$@") </dev/null; }
# listing <dir> : the names in <dir>, sorted, one per line, each between < and >.
listing() { (cd "$1" && ls -A | LC_ALL=C sort | sed 's/.*/<&>/'); }
oneline() { printf '%s' "$1" | tr '\n' ' '; }

src="$tmp/conf dir"
mkdir -p "$src/sub.conf" "$src/nested"
names=("plain.conf" "my app.conf" "two  spaces.conf" "it's.conf" 'say "hi".conf' "star*.conf" \
  "-dash.conf")
for name in "${names[@]}"; do printf 'content of %s\n' "$name" >"$src/$name"; done
echo "not a config" >"$src/notes.txt"
echo "nested" >"$src/nested/deep.conf"
echo "nested" >"$src/sub.conf/inner.conf"

dest="$tmp/my backups/today"
snap "$src" "$dest" >"$tmp/out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  || fail "snap.sh with special file names: wanted exit 0, got $rc: $(tail -n 3 "$tmp/out")"
want="$(for name in "${names[@]}"; do echo "$name.bak"; done | LC_ALL=C sort | sed 's/.*/<&>/')"
if [ ! -d "$dest" ]; then
  fail "snap.sh did not create DEST ($dest)"
else
  got="$(listing "$dest")"
  [ "$got" = "$want" ] || fail "DEST holds [$(oneline "$got")], wanted [$(oneline "$want")]"
  for name in "${names[@]}"; do
    [ ! -f "$dest/$name.bak" ] || cmp -s "$src/$name" "$dest/$name.bak" \
      || fail "$name.bak is not a copy of $name"
  done
fi

empty="$tmp/no confs"
mkdir -p "$empty" && echo "notes" >"$empty/notes.txt"
snap "$empty" "$tmp/empty out" >"$tmp/out" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "a SRC without *.conf files: wanted exit 0, got $rc: $(tail -n 3 "$tmp/out")"
[ -d "$tmp/empty out" ] && [ -z "$(ls -A "$tmp/empty out")" ] \
  || fail "a SRC without *.conf files: wanted an empty DEST, got [$(ls -A "$tmp/empty out" 2>&1)]"

snap "$src" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "one argument: wanted exit 2, got $rc"
snap "$src" "$tmp/a" "$tmp/b" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "three arguments: wanted exit 2, got $rc"

(cd "$repo" && make test) >"$tmp/test.log" 2>&1 || {
  fail "make test failed:"; tail -n 20 "$tmp/test.log"; }

[ "$failed" -eq 0 ] && echo "PASS: snap-spaces"
[ "$failed" -eq 0 ]
