#!/usr/bin/env bash
# vision.sh — offline tests for octo-vision-guard.sh, the VISION.md check in auto's merge gate.
#
# Usage:
#   bash scripts/test/vision.sh
#
# Against throwaway git repos, a PR branch is compared with main:
#   - passes: no VISION.md on either side, a PR that leaves VISION.md alone, one that changes
#     only Goal or Roadmap, a new VISION.md with no Immutable constraints section, heading-like
#     lines that are not level-1 or level-2 headings (indented code, ###, `##x`, plain text), a
#     human's change to the section on main that the PR merged or never saw, and all of that
#     under forced color, an external diff, and other diff settings in the git config;
#   - holds: a changed, emptied, removed, or renamed section, a new VISION.md with the section,
#     VISION.md deleted, made a symlink, or its mode changed, and a second heading named
#     Immutable constraints in ATX form (after a tab, indented up to 3 spaces, level 1, a closing
#     sequence, another case) or setext form (`=` or `-`, a paragraph over two lines);
#   - --milestone: a Roadmap item passes; a change outside the Roadmap, a heading added, and a
#     Roadmap without the milestone fail;
#   - bad arguments exit 2; a commit missing here, or a directory outside git, exits 3.
#
# Nothing here calls gh or the network. Git config is isolated (GIT_CONFIG_GLOBAL=/dev/null).
# Exits 0 when every check passes, 1 when any fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$(cd "$HERE/.." && pwd)/octo-vision-guard.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ✓ $1"; }
no() { fail=$((fail + 1)); echo "  ✗ $1"; }
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    no "$1"; printf '      wanted: %s\n      got:    %s\n' "$2" "$3"; fi
}
bounded() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "vision: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

G() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false \
  "${@:2}"; }
commit() { G "$1" add -A && G "$1" commit -q --no-verify --allow-empty -m "$2"; }

vision() {
  cat <<'MD'
# Vision

## Goal

A companion that remembers you.

## Immutable constraints

Only a human edits this section.

- Regular merge commits only.
- Conversation history never leaves the device.

## Roadmap

1. **MVP** — recall across turns.
MD
}
n=0
# fresh [novision] : a repo in $c with VISION.md (unless novision) and README.md on main, then
# a `pr` branch checked out.
fresh() {
  n=$((n + 1)); c="$tmp/c$n"
  mkdir -p "$c"
  [ "${1:-}" = novision ] || vision >"$c/VISION.md"
  echo readme >"$c/README.md"
  git init -q -b main "$c" && commit "$c" init && G "$c" switch -q -c pr
}
# edit <sed-script> : apply it to $c/VISION.md (BSD and GNU sed alike).
edit() { sed -i.bak "$1" "$c/VISION.md" && rm "$c/VISION.md.bak"; }
# run [args...] : the guard on $c, main against HEAD; sets out (lines joined by |) and rc.
run() {
  out="$(bounded 20 bash "$GUARD" --base main --head HEAD "$@" "$c" 2>/dev/null)"; rc=$?
  out="$(printf '%s' "$out" | paste -sd '|' -)"
}
UNCHANGED="0|ok: VISION.md: Immutable constraints unchanged"
CHANGED="1|FAIL: VISION.md: ## Immutable constraints changed: only a human edits that section"
FORGED="1|FAIL: VISION.md: a level-1 or level-2 heading named Immutable constraints was added or removed: only a human edits that section"

echo "• octo-vision-guard.sh: passes"
fresh novision
echo x >>"$c/README.md" && commit "$c" readme
run
same "no VISION.md on either side passes" "0|ok: VISION.md: none on either side" "$rc|$out"
fresh
echo x >>"$c/README.md" && commit "$c" readme
run
same "a PR that leaves VISION.md alone passes" "$UNCHANGED" "$rc|$out"
fresh
edit 's/^A companion that remembers you\.$/A companion that remembers everything./'
commit "$c" goal
run
same "a Goal-only change passes" "$UNCHANGED" "$rc|$out"
fresh
printf '2. **Milestone 2: Export** — every turn, in order\n' >>"$c/VISION.md" && commit "$c" rm
run
same "a Roadmap-only change passes" "$UNCHANGED" "$rc|$out"
fresh novision
printf '# Vision\n\n## Goal\n\nx\n\n## Roadmap\n\n1. y\n' >"$c/VISION.md" && commit "$c" add
run
same "a new VISION.md without Immutable constraints passes" "$UNCHANGED" "$rc|$out"
for h in '    ## Immutable constraints' '### Immutable constraints' '##Immutable constraints' \
    'Immutable constraints' '---'; do
  fresh
  printf '\n%s\n' "$h" >>"$c/VISION.md" && commit "$c" lookalike
  run
  same "a Roadmap line that is no level-1 or level-2 heading ('$h') passes" "$UNCHANGED" \
    "$rc|$out"
done
# The merge base decides: a human's change to the section on main is not the PR's.
fresh
G "$c" switch -q main
edit 's/^- Regular merge commits only\.$/- Regular merge commits only, always./'
commit "$c" human
G "$c" switch -q pr
echo x >>"$c/README.md" && commit "$c" readme
run
same "a human's later change on main, unseen by the PR, passes" "$UNCHANGED" "$rc|$out"
G "$c" merge -q --no-edit main
run
same "a human's change on main that the PR merged passes" "$UNCHANGED" "$rc|$out"

echo "• octo-vision-guard.sh: holds"
fresh
edit 's/^- Conversation history never leaves the device\.$/- Anything goes./'
commit "$c" change
run
same "a changed section holds" "$CHANGED" "$rc|$out"
fresh
edit '/^- /d'
commit "$c" empty
run
same "an emptied section holds" "$CHANGED" "$rc|$out"
fresh
edit '/^## Immutable constraints$/,/^- Conversation/d'
commit "$c" remove
run
same "a removed section holds" "$CHANGED|${FORGED#1|}" "$rc|$out"
fresh
edit 's/^## Immutable constraints$/## Immutable Constraints/'
commit "$c" rename
run
same "a renamed section heading holds" "$CHANGED" "$rc|$out"
fresh novision
vision >"$c/VISION.md" && commit "$c" add
run
same "a new VISION.md with Immutable constraints holds" "$CHANGED|${FORGED#1|}" "$rc|$out"
fresh
G "$c" rm -q VISION.md && commit "$c" delete
run
same "a deleted VISION.md holds" \
  "1|FAIL: VISION.md: deleted: only a human removes the constitution" "$rc|$out"
fresh
mkdir -p "$c/docs" && G "$c" mv VISION.md docs/VISION.md && ln -s docs/VISION.md "$c/VISION.md"
commit "$c" symlink
run
same "a symlinked VISION.md holds" \
  "1|FAIL: VISION.md: not a regular file (mode 120000): its Immutable constraints can't be read" \
  "$rc|$out"
fresh
chmod +x "$c/VISION.md" && commit "$c" mode
run
same "a mode change holds" "1|FAIL: VISION.md: its mode changed (100644 to 100755)" "$rc|$out"
# Each renders as a second Immutable constraints section, which the exact `## ` match misses.
for h in $'##\tImmutable constraints' ' ## Immutable constraints' '   ## Immutable constraints' \
    '# Immutable constraints' '## Immutable constraints ##' '##   immutable   CONSTRAINTS' \
    $'Immutable constraints\n=====' $'Immutable constraints\n---' $'  Immutable\nconstraints\n  -'
do
  fresh
  printf '\n%s\n\n- Anything goes.\n' "$h" >>"$c/VISION.md" && commit "$c" forged
  run
  same "a forged heading ('$(printf '%s' "$h" | sed 's/\t/<tab>/g' | paste -sd '/' -)') holds" \
    "$FORGED" "$rc|$out"
done

echo "• octo-vision-guard.sh under the user's git config"
# auto runs it in the user's clone: color, an external diff, and the rest must not change it.
cfg() {
  GIT_CONFIG_COUNT=6 GIT_CONFIG_KEY_0=color.ui GIT_CONFIG_VALUE_0=always \
    GIT_CONFIG_KEY_1=diff.external GIT_CONFIG_VALUE_1=true \
    GIT_CONFIG_KEY_2=diff.noprefix GIT_CONFIG_VALUE_2=true \
    GIT_CONFIG_KEY_3=core.quotePath GIT_CONFIG_VALUE_3=true \
    GIT_CONFIG_KEY_4=diff.relative GIT_CONFIG_VALUE_4=true \
    GIT_CONFIG_KEY_5=log.showSignature GIT_CONFIG_VALUE_5=true "$@"
}
fresh
printf '\n##\tImmutable constraints\n\n- Anything goes.\n' >>"$c/VISION.md" && commit "$c" forged
cfg run
same "a forged heading still holds" "$FORGED" "$rc|$out"
fresh
edit 's/^- Regular merge commits only\.$/- Squash is fine./'
commit "$c" change
cfg run
same "a changed section still holds" "$CHANGED" "$rc|$out"
fresh
printf '2. **Milestone 2** — next\n' >>"$c/VISION.md" && commit "$c" rm
cfg run
same "a Roadmap-only change still passes" "$UNCHANGED" "$rc|$out"

echo "• octo-vision-guard.sh --milestone"
MOK="0|ok: VISION.md: only ## Roadmap changed"
fresh
printf '2. **Milestone 2: Export** — every turn, in order\n' >>"$c/VISION.md" && commit "$c" rm
run --milestone 2
same "a Roadmap item for the milestone passes" "$MOK" "$rc|$out"
run --milestone 3
same "a Roadmap without the milestone fails" \
  "1|FAIL: VISION.md: ## Roadmap needs an item for Milestone 3" "$rc|$out"
fresh
edit 's/^A companion that remembers you\.$/A companion./'
printf '2. **Milestone 2** — next\n' >>"$c/VISION.md" && commit "$c" goal
run --milestone 2
same "a change outside ## Roadmap fails" "1|FAIL: VISION.md: only ## Roadmap may change" \
  "$rc|$out"
for h in $'##\tNotes' ' # Notes' $'Notes\n---' '#'; do
  fresh
  printf '2. **Milestone 2** — next\n\n%s\n' "$h" >>"$c/VISION.md" && commit "$c" heading
  run --milestone 2
  same "a heading added to the Roadmap ('$(printf '%s' "$h" | sed 's/\t/<tab>/g' | paste -sd '/' -)') fails" \
    "1|FAIL: VISION.md: a milestone adds no level-1 or level-2 heading, only Roadmap items" \
    "$rc|$out"
done

echo "• bad arguments and git failures"
fresh
for args in "" "--base main $c" "--head HEAD $c" "--base main --head HEAD" \
    "--base -x --head HEAD $c" "--base main --head --x $c" "--base main --head HEAD --milestone 0 $c" \
    "--base main --head HEAD --milestone x $c" "--base main --head HEAD --bogus $c" \
    "--base main --head HEAD $c $c" "--base main --head HEAD $tmp/missing" "--base"; do
  # shellcheck disable=SC2086 # each case is several words on purpose
  out="$(bounded 10 bash "$GUARD" $args 2>/dev/null)"; rc=$?
  same "bad arguments (${args:-none}) exit 2" "2|" "$rc|$out"
done
out="$(bounded 10 bash "$GUARD" --base main --head "$(printf '%040d' 1)" "$c" 2>/dev/null)"
same "a --head missing here exits 3" "3|" "$?|$out"
out="$(bounded 10 bash "$GUARD" --base origin/main --head HEAD "$c" 2>/dev/null)"
same "a --base missing here exits 3" "3|" "$?|$out"
mkdir -p "$tmp/nogit"
out="$(bounded 10 bash "$GUARD" --base main --head HEAD "$tmp/nogit" 2>/dev/null)"
same "a directory outside git exits 3" "3|" "$?|$out"

echo
echo "vision: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
