#!/usr/bin/env bash
# Tests for retry.sh. Run with: make test
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RETRY="$HERE/../retry.sh"
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: wanted $3, got $2"; failed=1; fi
}

# flaky <fail-count> : a command that exits 3 on its first <fail-count> runs, then 0. Counts its
# runs in $tmp/runs.
flaky() {
  rm -f "$tmp/runs"
  cat >"$tmp/flaky" <<SCRIPT
#!/usr/bin/env bash
echo x >>"$tmp/runs"
[ "\$(wc -l <"$tmp/runs")" -gt $1 ] || exit 3
SCRIPT
  chmod +x "$tmp/flaky"
}
runs() { wc -l <"$tmp/runs" | tr -d ' '; }

flaky 0
RETRY_DELAY=0 bash "$RETRY" "$tmp/flaky" 2>/dev/null
check "success on the first try exits 0" "$?" 0
check "success on the first try runs once" "$(runs)" 1

flaky 2
RETRY_DELAY=0 bash "$RETRY" "$tmp/flaky" 2>/dev/null
check "success on the third try exits 0" "$?" 0
check "success on the third try runs three times" "$(runs)" 3

flaky 99
RETRY_ATTEMPTS=4 RETRY_DELAY=0 bash "$RETRY" "$tmp/flaky" 2>/dev/null
check "giving up exits with the last status" "$?" 3
check "giving up stops at RETRY_ATTEMPTS" "$(runs)" 4

bash "$RETRY" 2>/dev/null
check "no command exits 2" "$?" 2

exit "$failed"
