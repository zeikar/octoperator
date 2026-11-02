#!/usr/bin/env bash
# octo-vision-guard.sh — tell auto's merge gate whether a PR changes VISION.md only where an
# agent may: VISION.md is the product constitution, and only its `## Roadmap` body is revisable
# without a human.
#
# Usage:
#   octo-vision-guard.sh --base REV --head REV [--milestone N] DIR
#
# DIR is a git repository that holds both commits, such as auto's clone. The guard reads git's
# objects (ls-tree, cat-file), never the work tree, so it needs no checkout, and no diff, color,
# textconv, or pathspec setting in the user's git config changes what it reads. It compares the
# root VISION.md at merge-base(--base, --head) with the one at --head, and allows a change only
# in the Roadmap body, as plain text. It never parses Markdown: what a renderer does with a line
# is not the guard's to guess, so anything that isn't plainly text holds the PR for a human.
#   - a root entry at --head other than VISION.md whose name folds to it (`vision.md`,
#     `Vision.md`, `viſion.md`: Unicode case folding, as macOS's default file system compares
#     names), new since the merge base or with another mode or object: FAIL, even with no
#     VISION.md. A case-insensitive checkout writes both to one file, so the reader could get the
#     other one's text while the guard checks VISION.md. One the merge base already had, as it
#     was, is a human's and passes;
#   - no VISION.md on either side: ok; one left as it was: ok;
#   - VISION.md deleted, new, --head's not a regular file (a symlink, a submodule, a directory),
#     or its mode changed: FAIL;
#   - --head's file holds a NUL, a CR not followed by LF, or another C0 control character but a
#     tab: FAIL. Tools and renderers split such a file differently, so a reader may not see
#     what the guard checked;
#   - the Roadmap body is everything after the merge base's line that is exactly `## Roadmap`
#     (a trailing CR aside) up to its next level-1 or level-2 heading line (up to 3 spaces, `#`
#     or `##`, then a blank or the line's end), or to the end. --head must keep the merge base's
#     bytes before that body (its Roadmap line included) and from that heading on: otherwise
#     FAIL, and with no `## Roadmap` line at the merge base any change does. So Goal, Target
#     users, Quality bar, and Immutable constraints change only through a human merge;
#   - each line of --head's Roadmap body, changed or not, must be plain text: FAIL for a line
#     that, after any blanks, opens with `<`, `#`, `>`, ``` or ~~~, or is only a run of `=` or
#     of `-`, or that holds `<!--`, `-->`, `?>`, `]]>`, `<` before a letter, `/`, `!`, or `?`
#     (raw HTML), or `]:` (a link definition). Those open or close what can hide, recast, or
#     re-link the sections around it. List items, indented continuation lines, code spans, and
#     `[text](url)` links pass.
# With --milestone N (genesis --next's check, octo-genesis-next.sh --check), also: the Roadmap
# body names `Milestone N`.
#
# Prints one `FAIL: VISION.md: <problem>` line per problem, or one `ok: VISION.md: …` line.
# Offline: git and perl only, never gh; writes nothing.
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
# Root names other than VISION.md that fold to it and are new or changed since the merge base,
# each with any byte outside printable ASCII shown as `?`. fc then NFD: macOS's file system
# ignores case and Unicode normalization.
g ls-tree -z --full-tree "$mb" >"$tmp/tree.base" || exit 3
g ls-tree -z --full-tree "$head" >"$tmp/tree.head" || exit 3
variants="$(perl -MUnicode::Normalize -Mfeature=fc -0 -ne 'chomp;
    my ($meta, $name) = split /\t/, $_, 2;
    if ($ARGV =~ /base$/) { $was{$name} = $meta; next }
    my $n = $name; utf8::decode($n);
    next if $name eq "VISION.md" || NFD(fc(NFD($n))) ne "vision.md";
    next if exists $was{$name} && $was{$name} eq $meta;
    $name =~ s/[^\x20-\x7e]/?/g; print "$name\n"' "$tmp/tree.base" "$tmp/tree.head")" || exit 3
[ -z "$variants" ] || fail "the root also holds $(printf '%s' "$variants" | paste -sd ' ' -)," \
  "which a case-insensitive checkout writes over VISION.md"
be="$(entry "$mb")" || exit 3
he="$(entry "$head")" || exit 3
if [ -z "$be" ] && [ -z "$he" ]; then
  [ "$FAILS" -eq 0 ] || exit 1
  echo "ok: VISION.md: none on either side"; exit 0
fi
[ -n "$he" ] || { fail "deleted: only a human removes the constitution"; exit 1; }
read -r hmode htype hobj <<<"$he"
case "$hmode" in
  100644 | 100755) ;;
  *) fail "not a regular file (mode $hmode): a reader may not get the text checked here"; exit 1 ;;
esac
if [ "$be" = "$he" ] && [ -z "$MILESTONE" ]; then
  [ "$FAILS" -eq 0 ] || exit 1
  echo "ok: VISION.md: unchanged"; exit 0
fi
[ -n "$be" ] || { fail "new: only a human adds the constitution"; exit 1; }
read -r bmode _ bobj <<<"$be"
[ "$bmode" = "$hmode" ] || { fail "its mode changed ($bmode to $hmode)"; exit 1; }
g cat-file blob "$bobj" >"$tmp/base" || exit 3
[ "$htype" = blob ] && g cat-file blob "$hobj" >"$tmp/head" || exit 3

# Bytes first, with perl on the file: awk and $(...) drop or stop at a NUL, and a bare CR is a
# line break to CommonMark but not to line tools.
bad="$(perl -0777 -ne 'my $what;
    if (/\x00/) { $what = "a NUL byte" }
    elsif (/\r(?!\n)/) { $what = "a CR not followed by LF" }
    elsif (/([\x01-\x08\x0b\x0c\x0e-\x1f])/) {
      $what = sprintf "a control character (0x%02x)", ord $1 }
    else { exit 0 }
    printf "line %d holds %s", 1 + (substr($_, 0, $-[0]) =~ tr/\n//), $what' "$tmp/head")" || exit 3
[ -z "$bad" ] || { fail "$bad: a reader may not see the text checked here, so a human merges it"
  exit 1; }

# Split at the merge base's Roadmap body: base.pre (up to and including its `## Roadmap` line)
# and base.suf (from its next level-1 or level-2 heading line, or empty); head.pre and head.suf
# are --head's bytes in the same places, head.mid what lies between, its first line's number in
# head.line. Prints `noroadmap`, `outside` (--head can't hold both around whole lines), or `ok`.
# The Immutable constraints section of each side goes to imm.base and imm.head, for the reason.
split="$(perl -e 'use strict; my $d = shift;
    sub slurp { local $/; open my $f, "<:raw", $_[0] or die "$_[0]: $!"; my $s = <$f>; $s // "" }
    sub put { open my $f, ">:raw", "$d/$_[0]" or die "$d/$_[0]: $!"; print $f $_[1]; close $f }
    my $heading = qr/^ {0,3}##?(?:[ \t]|\r?\n|\r?\z)/m;
    my ($bs, $h) = (slurp("$d/base"), slurp("$d/head"));
    for (["base", $bs], ["head", $h]) {
      my ($side, $s) = @$_; my $sec = "";
      if ($s =~ /^## Immutable constraints\r?(?:\n|\z)/mg) {
        my $from = pos $s; $sec = substr $s, $from;
        $sec = substr $sec, 0, $-[0] if $sec =~ $heading;
      }
      put("imm.$side", $sec);
    }
    unless ($bs =~ /^## Roadmap(?:\r?\n|\z)/mg) { print "noroadmap"; exit 0 }
    my $pre = substr $bs, 0, pos $bs; my $rest = substr $bs, pos $bs;
    my $suf = $rest =~ $heading ? substr($rest, $-[0]) : "";
    put("base.pre", $pre); put("base.suf", $suf);
    if (length $h < length($pre) + length $suf) { print "outside"; exit 0 }
    put("head.pre", substr $h, 0, length $pre);
    put("head.suf", length $suf ? substr($h, -length $suf) : "");
    my $mid = substr $h, length $pre, length($h) - length($pre) - length $suf;
    my $line = 1 + ($pre =~ tr/\n//);
    # A Roadmap line at the end of the file with no LF: the body starts after the one --head adds.
    if ($pre !~ /\n\z/ && length $mid) {
      if ($mid =~ s/\A\r?\n//) { $line++ } else { print "outside"; exit 0 }
    }
    # The body ends at a line end, so the heading after it stays a line of its own.
    if (length $suf && length $mid && $mid !~ /\n\z/) { print "outside"; exit 0 }
    put("head.mid", $mid); put("head.line", $line); print "ok"' "$tmp")" || exit 3

OUTSIDE="only the ## Roadmap body may change without a human"
case "$split" in
  noroadmap) fail "it has no line that is exactly '## Roadmap' at the merge base, so any change" \
       "needs a human"; exit 1 ;;
  outside) ;;
  ok) cmp -s "$tmp/base.pre" "$tmp/head.pre" && cmp -s "$tmp/base.suf" "$tmp/head.suf" \
        || split=outside ;;
  *) echo "could not split VISION.md" >&2; exit 3 ;;
esac
if [ "$split" = outside ]; then
  if cmp -s "$tmp/imm.base" "$tmp/imm.head"; then fail "$OUTSIDE"
  else fail "## Immutable constraints changed: only a human edits that section"; fi
  exit 1
fi

# Each body line must be plain text (the header lists what isn't). Prints the first that isn't.
notext="$(perl -ne 'BEGIN { open my $f, "<", shift or die; $n = <$f>; $n-- }
    $n++; chomp; s/\r\z//;
    next unless /^[ \t]*(?:<|#|>|```|~~~)/ || /^[ \t]*(?:=+|-+)[ \t]*$/
      || /<!--|-->|\?>|\]\]>|<[A-Za-z\/!?]|\]:/;
    print "$n"; exit 0' "$tmp/head.line" "$tmp/head.mid")" || exit 3
[ -z "$notext" ] || fail "line $notext of the ## Roadmap body is not plain text (a heading, HTML," \
  "a quote, a fence, an = or - underline, or a link definition): a human merges it"
if [ -n "$MILESTONE" ]; then
  grep -Eq "Milestone $MILESTONE([^0-9]|$)" "$tmp/head.mid" \
    || fail "## Roadmap needs an item for Milestone $MILESTONE"
fi

[ "$FAILS" -eq 0 ] || exit 1
if cmp -s "$tmp/base" "$tmp/head"; then echo "ok: VISION.md: unchanged"
else echo "ok: VISION.md: only the ## Roadmap body changed"; fi
