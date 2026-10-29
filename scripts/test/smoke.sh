#!/usr/bin/env bash
# smoke.sh — CI-safe smoke checks for the octo-*.sh helper scripts.
#
# Verifies each helper's parse surface WITHOUT any network / gh / auth, so it
# runs anywhere (CI, a fresh clone, offline):
#   - bash -n <script>     : the script parses (no syntax errors)
#   - <script> --help      : exits 0 and prints usage
#   - <script> --bogus     : exits 2 (unknown-argument handling)
#
#   - octo-setup.sh --repo : a missing flag value exits 2 instead of hanging
#   - octo-exclude.sh      : run for real against a throwaway local `git init` repo
#
# It deliberately never invokes a helper in a way that reaches gh / the network.
# Exits 0 when every check passes, 1 when any check fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ✓ $1"; }
no() { fail=$((fail + 1)); echo "  ✗ $1"; }

# expect <wanted-exit> <label> <command...>
expect() {
  wanted="$1"; label="$2"; shift 2
  "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$wanted" ]; then ok "$label (exit $rc)"; else no "$label (wanted $wanted, got $rc)"; fi
}

shopt -s nullglob
scripts=("$SCRIPTS_DIR"/octo-*.sh)
if [ "${#scripts[@]}" -eq 0 ]; then
  echo "smoke: no octo-*.sh scripts found in $SCRIPTS_DIR" >&2
  exit 1
fi

for s in "${scripts[@]}"; do
  echo "• $(basename "$s")"
  expect 0 "syntax (bash -n)"    bash -n "$s"
  expect 0 "--help exits 0"      bash "$s" --help
  expect 2 "unknown arg exits 2" bash "$s" --octo-smoke-bogus-arg
done

# bounded <seconds> <command...> : SIGALRM-kill a hung command (macOS has no `timeout`).
bounded() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }

echo "• octo-setup.sh (arg parsing)"
# A trailing flag with no value must fail fast, not spin on a failed `shift 2`.
expect 2 "missing --repo value exits 2" bounded 10 bash "$SCRIPTS_DIR/octo-setup.sh" --repo

echo "• octo-exclude.sh (offline, temp repo)"
# No `set -e`: bail out explicitly, or an empty $tmp would point git/cd at the real checkout.
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "smoke: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q || { echo "smoke: git init failed in $tmp" >&2; exit 1; }
mkdir -p "$tmp/.claude" "$tmp/.octoperator/worktrees/1-x"
touch "$tmp/.claude/octoperator.local.md" "$tmp/.octoperator/worktrees/1-x/f"
printf '*.swp' >"$tmp/.git/info/exclude"   # no trailing newline: appends must not join this line
exclude_in_tmp() { (cd "$tmp" && bash "$SCRIPTS_DIR/octo-exclude.sh"); }
expect 0 "first run exits 0"  exclude_in_tmp
expect 0 "second run exits 0" exclude_in_tmp
expect 0 "octoperator files hidden from status" test -z "$(git -C "$tmp" status --porcelain)"
expect 0 "idempotent (one entry each)" test "$(grep -Fxc -e /.claude/octoperator.local.md -e /.octoperator/ "$tmp/.git/info/exclude")" -eq 2
expect 0 "existing entry preserved" grep -Fqx '*.swp' "$tmp/.git/info/exclude"

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
