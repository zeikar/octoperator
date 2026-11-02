#!/usr/bin/env bash
# vision.sh — offline tests for octo-vision-guard.sh, the VISION.md check in auto's merge gate.
#
# Usage:
#   bash scripts/test/vision.sh
#
# Against throwaway git repos, a PR branch is compared with main:
#   - passes: no VISION.md on either side, a PR that leaves VISION.md alone, plain Roadmap lines
#     added (a list item, an indented continuation, a code span, a link), with a section after
#     the Roadmap kept, a Roadmap line at the end with no LF, a CRLF file, a human's change on
#     main that the PR merged or never saw, Octoperator's own VISION.md left alone or given a
#     Roadmap item, a root twin of VISION.md the merge base already had, unchanged, a vision.md
#     below the root, and all of that under forced color, an external diff, and other diff
#     settings in the git config;
#   - holds: a change outside the Roadmap body (Goal, Immutable constraints, the Roadmap heading,
#     the section after it, front matter on line 1, a section moved or removed, each HTML block
#     type or a comment or fence mark moved there), a base with no `## Roadmap`, a new VISION.md,
#     VISION.md deleted, made a symlink, or its mode changed, a NUL, a bare CR, or another
#     control character, a Roadmap line that is not plain text (a heading at any indent, each
#     HTML block opener, `<details>` and `<div>`, inline HTML, a comment or CDATA end, a quote,
#     a fence, a setext or `-` underline, a link definition), a last Roadmap line that runs into
#     the next heading, and a root name that folds to VISION.md (`vision.md`, `viſion.md`, a
#     directory, also with no VISION.md) when it is new or changed;
#   - --milestone: a Roadmap item passes; a change outside the Roadmap, a heading, a bare CR, and
#     a Roadmap without the milestone fail;
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
# fresh [novision|notes|crlf] : a repo in $c with VISION.md (unless novision; with a `## Notes`
# section after the Roadmap for notes; with CRLF line ends for crlf) and README.md on main,
# then a `pr` branch checked out.
fresh() {
  n=$((n + 1)); c="$tmp/c$n"
  mkdir -p "$c"
  case "${1:-}" in
    novision) ;;
    notes) { vision; printf '\n## Notes\n\nKept as it is.\n'; } >"$c/VISION.md" ;;
    crlf) vision | perl -pe 's/\n/\r\n/' >"$c/VISION.md" ;;
    *) vision >"$c/VISION.md" ;;
  esac
  echo readme >"$c/README.md"
  git init -q -b main "$c" && commit "$c" init && G "$c" switch -q -c pr
}
# edit <perl-expr> : apply it to $c/VISION.md, read whole (-0777), so it can add any byte.
edit() { perl -0777 -pi -e "$1" "$c/VISION.md"; }
# add <text> : append it to $c/VISION.md, then commit.
add() { printf '%s' "$1" >>"$c/VISION.md" && commit "$c" add; }
# run [args...] : the guard on $c, main against HEAD; sets out (lines joined by |) and rc.
run() {
  out="$(bounded 20 bash "$GUARD" --base main --head HEAD "$@" "$c" 2>/dev/null)"; rc=$?
  out="$(printf '%s' "$out" | paste -sd '|' -)"
}
UNCHANGED="0|ok: VISION.md: unchanged"
ROADMAP="0|ok: VISION.md: only the ## Roadmap body changed"
OUTSIDE="1|FAIL: VISION.md: only the ## Roadmap body may change without a human"
CHANGED="1|FAIL: VISION.md: ## Immutable constraints changed: only a human edits that section"
# notext <line> : the hold for a Roadmap body line that is not plain text.
notext() {
  printf '1|FAIL: VISION.md: line %s of the ## Roadmap body is not plain text (a heading, HTML, %s' \
    "$1" "a quote, a fence, an = or - underline, or a link definition): a human merges it"
}
# bytes <line> <what> : the hold for a byte a reader may not see.
bytes() {
  printf '1|FAIL: VISION.md: line %s holds %s: a reader may not see the text checked here, so a %s' \
    "$1" "$2" "human merges it"
}
# show <text> : a case's text for its label, a tab as <tab> and line breaks as /.
show() { printf '%s' "$1" | sed 's/\t/<tab>/g' | paste -sd '/' -; }

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
add $'2. **Milestone 2: Export** — every turn, in order\n'
run
same "a Roadmap list item added passes" "$ROADMAP" "$rc|$out"
# Plain text: a list item, an indented continuation, a code span, a link, a thematic `***`.
for l in '- a sub-item' '   continued on an indented line' '* starred' \
    '2. With `inline code` and a [link](https://x.example/a) — fine' '***' \
    'Not a heading: Immutable constraints' $'\tindented with a tab'; do
  fresh
  add "$(printf '\n%s\n' "$l")"$'\n'
  run
  same "a plain Roadmap line ('$(show "$l")') passes" "$ROADMAP" "$rc|$out"
done
fresh notes
edit 's/(1\. \*\*MVP\*\* — recall across turns\.\n)/$1   Continued.\n2. **Next** — more.\n/'
commit "$c" mid
run
same "a Roadmap item with a section after the Roadmap kept passes" "$ROADMAP" "$rc|$out"
# A Roadmap line at the file's end with no LF: the body starts after the LF the PR adds.
fresh novision
printf '# Vision\n\n## Goal\n\nx\n\n## Roadmap' >"$c/VISION.md" && commit "$c" bare
G "$c" branch -q -f main HEAD
add $'\n\n1. **MVP** — first.\n'
run
same "items under a Roadmap line that ended the file pass" "$ROADMAP" "$rc|$out"
fresh crlf
add $'2. **Milestone 2** \xe2\x80\x94 next\r\n'
run
same "a CRLF file with a Roadmap item appended passes" "$ROADMAP" "$rc|$out"
run --milestone 2
same "a CRLF file with a Roadmap item appended passes --milestone" "$ROADMAP" "$rc|$out"
# The merge base decides: a human's change to the section on main is not the PR's.
fresh
G "$c" switch -q main
edit 's/^- Regular merge commits only\.$/- Regular merge commits only, always./m'
commit "$c" human
G "$c" switch -q pr
echo x >>"$c/README.md" && commit "$c" readme
run
same "a human's later change on main, unseen by the PR, passes" "$UNCHANGED" "$rc|$out"
G "$c" merge -q --no-edit main
run
same "a human's change on main that the PR merged passes" "$UNCHANGED" "$rc|$out"
# Octoperator's own VISION.md: left alone, or given a Roadmap item, it passes.
fresh
cp "$HERE/../../VISION.md" "$c/VISION.md" && commit "$c" octoperator \
  && G "$c" branch -q -f main HEAD
echo x >>"$c/README.md" && commit "$c" readme
run
same "Octoperator's own VISION.md, left alone, passes" "$UNCHANGED" "$rc|$out"
add $'7. **Next** \xe2\x80\x94 a Roadmap item, citing [#66](https://github.com/zeikar/octoperator/issues/66)\n   and wrapped.\n'
run
same "Octoperator's own VISION.md with a Roadmap item passes" "$ROADMAP" "$rc|$out"

echo "• octo-vision-guard.sh: holds a change outside the Roadmap body"
fresh
edit 's/^A companion that remembers you\.$/A companion that remembers everything./m'
commit "$c" goal
run
same "a Goal change holds" "$OUTSIDE" "$rc|$out"
fresh
edit 's/^- Conversation history never leaves the device\.$/- Anything goes./m'
commit "$c" change
run
same "a changed Immutable constraints section holds" "$CHANGED" "$rc|$out"
fresh
edit 's/^## Immutable constraints\n.*?(?=^## Roadmap)//ms'
commit "$c" remove
run
same "a removed Immutable constraints section holds" "$CHANGED" "$rc|$out"
fresh
edit 's/(## Immutable constraints.*?)(## Roadmap.*)/$2\n$1/s'
commit "$c" move
run
same "the section moved below the Roadmap holds" "$OUTSIDE" "$rc|$out"
fresh
edit 's/^## Roadmap$/## Roadmap (revisable)/m'
commit "$c" rename
run
same "a renamed Roadmap heading holds" "$OUTSIDE" "$rc|$out"
fresh
edit 's/\A/---\ntitle: x\n---\n/'
commit "$c" front
run
same "front matter added on line 1 holds" "$OUTSIDE" "$rc|$out"
fresh notes
edit 's/Kept as it is\./Changed./'
commit "$c" notes
run
same "a change to the section after the Roadmap holds" "$OUTSIDE" "$rc|$out"
fresh notes
edit 's/\n\n## Notes/\nrunning on## Notes/'
commit "$c" join
run
same "a Roadmap line that runs into the next heading holds" "$OUTSIDE" "$rc|$out"
# Each HTML block type, or a moved comment or fence mark, around the section: outside the body.
for wrap in '<?|?>' '<!X|>' '<![CDATA[|]]>' '<script>|</script>' '<!--|-->' \
    '<details><summary>Superseded</summary>|</details>' '<div>|' '```|```'; do
  fresh
  o="${wrap%%|*}" e="${wrap#*|}"
  O="$o" E="$e" perl -0777 -pi -e \
    's/\n## Immutable constraints/\n$ENV{O}\n## Immutable constraints/; s/(\n## Roadmap\n)/$1$ENV{E}\n/ if length $ENV{E}' \
    "$c/VISION.md"
  commit "$c" wrap
  run
  same "the section wrapped in '$o' … '$e' holds" "$OUTSIDE" "$rc|$out"
done
# Marks the base already had, moved: a comment split, a fence's close moved down.
fresh novision
vision | perl -0777 -pe 's/(\n## Goal\n)/$1\n<!-- owner: t -->\n/; s/(\n## Immutable constraints\n)/\n```\nmake test\n```\n$1/' \
  >"$c/VISION.md" && commit "$c" marks && G "$c" branch -q -f main HEAD
edit 's/<!-- owner: t -->/<!-- owner: t/; s/(\n## Roadmap\n)/$1-->\n/'
commit "$c" split
run
same "a comment mark the base had, moved, holds" "$OUTSIDE" "$rc|$out"
G "$c" reset -q --hard main
edit 's/make test\n```\n/make test\n/; s/(\n## Roadmap\n)/$1```\n/'
commit "$c" fence
run
same "a fence mark the base had, moved, holds" "$OUTSIDE" "$rc|$out"
fresh novision
printf '# Vision\n\n## Goal\n\nx\n' >"$c/VISION.md" && commit "$c" noroadmap \
  && G "$c" branch -q -f main HEAD
add $'\n## Roadmap\n\n1. y\n'
run
same "any change to a VISION.md with no ## Roadmap holds" \
  "1|FAIL: VISION.md: it has no line that is exactly '## Roadmap' at the merge base, so any change needs a human" \
  "$rc|$out"

echo "• octo-vision-guard.sh: holds the file itself"
fresh novision
vision >"$c/VISION.md" && commit "$c" add
run
same "a new VISION.md holds" "1|FAIL: VISION.md: new: only a human adds the constitution" "$rc|$out"
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
  "1|FAIL: VISION.md: not a regular file (mode 120000): a reader may not get the text checked here" \
  "$rc|$out"
fresh
chmod +x "$c/VISION.md" && commit "$c" mode
run
same "a mode change holds" "1|FAIL: VISION.md: its mode changed (100644 to 100755)" "$rc|$out"
# Bytes a reader may not see: awk and $(...) drop or stop at a NUL, and CommonMark breaks a line
# at a bare CR that line tools don't.
fresh
edit 's/(- Regular merge commits only\.)/$1\x00 Superseded: squash is fine./'
commit "$c" nul
run
same "a NUL in the Immutable constraints holds" "$(bytes 11 'a NUL byte')" "$rc|$out"
fresh
edit 's/\z/2. **Next**\x00\n## Immutable constraints\n/'
commit "$c" nul
run
same "a NUL in the Roadmap holds" "$(bytes 17 'a NUL byte')" "$rc|$out"
fresh
add $'2. More\r\r## Immutable constraints\r\r- Agents may squash-merge.\n'
run
same "a bare CR in the Roadmap holds" "$(bytes 17 'a CR not followed by LF')" "$rc|$out"
run --milestone 2
same "a bare CR in the Roadmap holds --milestone" "$(bytes 17 'a CR not followed by LF')" \
  "$rc|$out"
fresh
add $'2. More \x1b[8mhidden\x1b[0m\n'
run
same "an escape character holds" "$(bytes 17 'a control character (0x1b)')" "$rc|$out"

echo "• octo-vision-guard.sh: holds a Roadmap line that is not plain text"
for l in '## Immutable constraints' $'##\tImmutable constraints' '   ## Immutable constraints' \
    '    ## Immutable constraints' '# Archive' '### Immutable constraints (amended)' \
    '##not a heading' '#' '<?' '<!X' '<![CDATA[' '<script>' '<!-- note -->' '<details>' \
    '<div>' '</details>' '<span>x</span>' '> quoted' '```' '~~~' '  ```' '===' '---' '  -' \
    'Text then <details> inline' 'a CDATA end ]]>' 'a comment end -->' 'a PI end ?>' \
    '[Immutable constraints]: https://x.example "Anything goes"' '- <div>'; do
  fresh
  add "$(printf '\n%s\n\n- Anything goes.\n' "$l")"$'\n'
  run
  same "a Roadmap line '$(show "$l")' holds" "$(notext 18)" "$rc|$out"
done
fresh
add $'\nImmutable constraints\n=====\n'
run
same "a setext underline in the Roadmap holds" "$(notext 19)" "$rc|$out"
# Every line of the body counts, so a line the base already had holds an otherwise plain change.
fresh novision
{ vision; printf '\n<details>\n'; } >"$c/VISION.md" && commit "$c" base \
  && G "$c" branch -q -f main HEAD
add $'2. **Next**\n'
run
same "a Roadmap the base left with HTML holds the next change" "$(notext 18)" "$rc|$out"

echo "• octo-vision-guard.sh: root twins"
# Case-only twins: a macOS checkout writes vision.md over VISION.md, so its text would win. Built
# with update-index, since this file system may not hold both names.
twin() {
  local obj
  obj="$(printf '%s\n' "${2:-x}" | G "$c" hash-object -w --stdin)" \
    && G "$c" update-index --add --cacheinfo "100644,$obj,$1" && G "$c" commit -q -m twin
}
TWIN="FAIL: VISION.md: the root also holds"
# Each case is <path to add>=<the name the guard prints>; ſ folds to s, its bytes print as `?`.
for t in vision.md=vision.md Vision.md=Vision.md $'vi\xc5\xbfion.md=vi??ion.md' \
    VISION.MD/x=VISION.MD; do
  fresh
  twin "${t%%=*}"
  run
  same "a new root twin ('${t#*=}') holds" \
    "1|$TWIN ${t#*=}, which a case-insensitive checkout writes over VISION.md" "$rc|$out"
done
fresh novision
twin vision.md
run
same "a new root vision.md holds with no VISION.md either" \
  "1|$TWIN vision.md, which a case-insensitive checkout writes over VISION.md" "$rc|$out"
# A twin the merge base already had is a human's: it passes until the PR changes it. README only
# is staged, so the index's twin entry is not re-read from this file system.
fresh
twin vision.md && G "$c" branch -q -f main HEAD
echo x >>"$c/README.md" && G "$c" add README.md && G "$c" commit -q -m readme
run
same "an unchanged root twin the base had passes" "$UNCHANGED" "$rc|$out"
twin vision.md changed
run
same "a changed root twin holds" \
  "1|$TWIN vision.md, which a case-insensitive checkout writes over VISION.md" "$rc|$out"
fresh
twin docs/vision.md
run
same "a vision.md below the root passes" "$UNCHANGED" "$rc|$out"

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
add $'\n##\tImmutable constraints\n\n- Anything goes.\n'
cfg run
same "a Roadmap heading still holds" "$(notext 18)" "$rc|$out"
fresh
edit 's/^- Regular merge commits only\.$/- Squash is fine./m'
commit "$c" change
cfg run
same "a changed section still holds" "$CHANGED" "$rc|$out"
fresh
add $'2. **Milestone 2** \xe2\x80\x94 next\n'
cfg run
same "a Roadmap-only change still passes" "$ROADMAP" "$rc|$out"

echo "• octo-vision-guard.sh --milestone"
fresh
add $'2. **Milestone 2: Export** \xe2\x80\x94 every turn, in order\n'
run --milestone 2
same "a Roadmap item for the milestone passes" "$ROADMAP" "$rc|$out"
run --milestone 3
same "a Roadmap without the milestone fails" \
  "1|FAIL: VISION.md: ## Roadmap needs an item for Milestone 3" "$rc|$out"
fresh
edit 's/^A companion that remembers you\.$/A companion./m'
printf '2. **Milestone 2** — next\n' >>"$c/VISION.md" && commit "$c" goal
run --milestone 2
same "a change outside ## Roadmap fails" "$OUTSIDE" "$rc|$out"
for h in $'##\tNotes' ' # Notes' '#'; do
  fresh
  add "$(printf '2. **Milestone 2** — next\n\n%s\n' "$h")"$'\n'
  run --milestone 2
  same "a heading added to the Roadmap ('$(show "$h")') fails" "$(notext 19)" "$rc|$out"
done
fresh
add $'2. **Milestone 2** \xe2\x80\x94 next\n\nNotes\n---\n'
run --milestone 2
same "a setext heading added to the Roadmap fails" "$(notext 20)" "$rc|$out"

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
