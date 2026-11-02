#!/usr/bin/env bash
# octo-vision-guard.sh — tell auto's merge gate whether a PR leaves VISION.md's Immutable
# constraints alone: VISION.md says only a human edits that section.
#
# Usage:
#   octo-vision-guard.sh --base REV --head REV [--milestone N] DIR
#
# DIR is a git repository that holds both commits, such as auto's clone. The guard reads git's
# objects (ls-tree, cat-file), never the work tree, so it needs no checkout, and no diff, color,
# textconv, or pathspec setting in the user's git config changes what it reads. It compares the
# root VISION.md at merge-base(--base, --head) with the one at --head:
#   - no VISION.md on either side: ok;
#   - VISION.md deleted, --head's not a regular file (a symlink, a submodule, a directory), or
#     its mode changed: FAIL;
#   - the `## Immutable constraints` section (from that exact heading line, trailing blanks
#     aside, to the next `## ` line) differs: FAIL. A side with no such section has an empty
#     one, so adding a section counts too;
#   - the number of level-1 or level-2 headings named Immutable constraints differs: FAIL. A
#     heading is CommonMark's ATX form (up to 3 spaces, `#` or `##`, then a space, a tab, or the
#     line's end, so `##<tab>x` and ` ## x` count) or a setext one (a paragraph underlined with
#     `=` or `-`, up to 3 spaces before it); names compare without case, a closing `#`
#     sequence, or extra blanks. So a heading that renders as a second Immutable constraints
#     section, where the exact match above doesn't see it, holds the PR. Fenced code isn't
#     parsed: a heading-like line in one counts, which can only hold more.
# With --milestone N (genesis --next's check, octo-genesis-next.sh --check), also: nothing outside
# `## Roadmap` changes, the level-1 and level-2 headings are the same ones in the same order (a
# milestone adds none), and the Roadmap names `Milestone N`.
#
# Prints one `FAIL: VISION.md: <problem>` line per problem, or one `ok: VISION.md: …` line.
# Offline: git only, never gh; writes nothing.
#
# Exit codes: 0 ok, 1 `FAIL:` lines (hold the PR), 2 bad arguments or DIR is not a directory,
# 3 git failed (not a repository, a commit missing here, no merge base; git's output on stderr).
set -uo pipefail
export LC_ALL=C

BASE="" HEADREV="" MILESTONE="" DIR=""
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --base) need_value "$@"; BASE="$2"; shift 2 ;;
    --head) need_value "$@"; HEADREV="$2"; shift 2 ;;
    --milestone) need_value "$@"; MILESTONE="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$DIR" ] || { echo "Only one DIR may be given" >&2; exit 2; }
       DIR="$1"; shift ;;
  esac
done
[ -n "$BASE" ] && [ -n "$HEADREV" ] && [ -n "$DIR" ] || {
  echo "Usage: octo-vision-guard.sh --base REV --head REV [--milestone N] DIR" >&2; exit 2; }
# A rev that starts with `-` would reach git as an option.
case "$BASE" in -*) echo "--base must be a revision" >&2; exit 2 ;; esac
case "$HEADREV" in -*) echo "--head must be a revision" >&2; exit 2 ;; esac
[ -z "$MILESTONE" ] || [[ "$MILESTONE" =~ ^[1-9][0-9]*$ ]] \
  || { echo "--milestone must be a positive number" >&2; exit 2; }
[ -d "$DIR" ] || { echo "Not a directory: $DIR" >&2; exit 2; }

FAILS=0
fail() { echo "FAIL: VISION.md: $*"; FAILS=$((FAILS + 1)); }
g() { git -C "$DIR" --literal-pathspecs "$@"; }
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "mktemp failed" >&2; exit 3; }
trap 'rm -rf "$tmp"' EXIT

head="$(g rev-parse --verify -q "$HEADREV^{commit}")" \
  || { echo "--head $HEADREV is not a commit in $DIR" >&2; exit 3; }
base="$(g rev-parse --verify -q "$BASE^{commit}")" \
  || { echo "--base $BASE is not a commit in $DIR" >&2; exit 3; }
mb="$(g merge-base "$base" "$head")" || { echo "git merge-base $BASE $HEADREV failed" >&2; exit 3; }

# entry <commit> : VISION.md's tree entry at the repo root, `<mode> <type> <object>`, or nothing.
entry() {
  local e
  e="$(g ls-tree --full-tree "$1" -- VISION.md)" || return 1
  printf '%s' "${e%%$'\t'*}"
}
be="$(entry "$mb")" || exit 3
he="$(entry "$head")" || exit 3
if [ -z "$be" ] && [ -z "$he" ]; then echo "ok: VISION.md: none on either side"; exit 0; fi
[ -n "$he" ] || { fail "deleted: only a human removes the constitution"; exit 1; }
read -r hmode htype hobj <<<"$he"
case "$hmode" in
  100644 | 100755) ;;
  *) fail "not a regular file (mode $hmode): its Immutable constraints can't be read"; exit 1 ;;
esac
: >"$tmp/base"
if [ -n "$be" ]; then
  read -r bmode btype bobj <<<"$be"
  [ "$bmode" = "$hmode" ] || fail "its mode changed ($bmode to $hmode)"
  if [ "$btype" = blob ]; then g cat-file blob "$bobj" >"$tmp/base" || exit 3; fi
fi
[ "$htype" = blob ] && g cat-file blob "$hobj" >"$tmp/head" || exit 3

# section_of <name> <file> : the body of each `## <name>` section, trailing blanks aside.
section_of() {
  awk -v s="## $1" '{ line = $0; sub(/[ \t\r]+$/, "", line) }
    line ~ /^## / { on = (line == s); next } on' "$2"
}
# without <name> <file> : the file with that section's body left out.
without() {
  awk -v s="## $1" '{ line = $0; sub(/[ \t\r]+$/, "", line) }
    line ~ /^## / { skip = (line == s); print; next } !skip' "$2"
}
# headings <file> : each level-1 or level-2 heading as `<level> <name>`, the name lowercased
# with its blanks collapsed (CommonMark's ATX and setext forms, as the header says).
headings() {
  awk 'function name(s) { s = tolower(s); gsub(/[ \t]+/, " ", s); sub(/^ /, "", s)
                          sub(/ $/, "", s); return s }
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^[ \t]*$/ { para = ""; next }
    line ~ /^(   |  | )?##?([ \t]|$)/ {
      t = line; sub(/^ *#/, "", t); lvl = 1
      if (t ~ /^#/) { t = substr(t, 2); lvl = 2 }
      # A closing sequence: blanks, then only #s, to the end; a heading of only #s is empty.
      if (t ~ /^[ \t#]*$/) t = ""; else sub(/[ \t]+#+[ \t]*$/, "", t)
      print lvl, name(t); para = ""; next }
    para != "" && line ~ /^(   |  | )?(=+|-+)[ \t]*$/ {
      print (line ~ /=/ ? 1 : 2), name(para); para = ""; next }
    # A thematic break ends a paragraph; so does nothing else here but a blank or a heading.
    line ~ /^(   |  | )?(\*[ \t]*\*[ \t]*\*[*\t ]*|_[ \t]*_[ \t]*_[_\t ]*|-[ \t]*-[ \t]*-[-\t ]*)$/ {
      para = ""; next }
    # An indented line opens no paragraph (it is code), though it may continue one.
    para == "" && line ~ /^(    |\t)/ { next }
    { para = (para == "" ? line : para " " line) }' "$1"
}

if [ "$(section_of 'Immutable constraints' "$tmp/base")" \
    != "$(section_of 'Immutable constraints' "$tmp/head")" ]; then
  fail "## Immutable constraints changed: only a human edits that section"
elif [ -n "$MILESTONE" ] && [ "$(without Roadmap "$tmp/base")" != "$(without Roadmap "$tmp/head")" ]
then
  fail "only ## Roadmap may change"
fi
headings "$tmp/base" >"$tmp/h.base" || exit 3
headings "$tmp/head" >"$tmp/h.head" || exit 3
ic() { grep -Ec '^[12] immutable constraints$' "$1"; }
[ "$(ic "$tmp/h.base")" = "$(ic "$tmp/h.head")" ] \
  || fail "a level-1 or level-2 heading named Immutable constraints was added or removed: only" \
       "a human edits that section"
if [ -n "$MILESTONE" ]; then
  cmp -s "$tmp/h.base" "$tmp/h.head" \
    || fail "a milestone adds no level-1 or level-2 heading, only Roadmap items"
  section_of Roadmap "$tmp/head" | grep -Eq "Milestone $MILESTONE([^0-9]|$)" \
    || fail "## Roadmap needs an item for Milestone $MILESTONE"
fi

[ "$FAILS" -eq 0 ] || exit 1
if [ -n "$MILESTONE" ]; then echo "ok: VISION.md: only ## Roadmap changed"
else echo "ok: VISION.md: Immutable constraints unchanged"; fi
