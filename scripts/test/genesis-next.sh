#!/usr/bin/env bash
# genesis-next.sh — offline tests for octo-genesis-next.sh, the offline half of `genesis --next`.
#
# Usage:
#   bash scripts/test/genesis-next.sh
#
#   - --rev   : the next milestone's number (2 after the MVP, 1 + the highest ## Milestone
#               heading after that) and requirement id, read from git's objects at the rev
#               rather than the work tree; a --tip that differs, a rev that isn't a commit, a
#               rev missing a product doc, and a directory outside git
#   - --check : against throwaway git repos, a valid grounded milestone and a valid ungrounded
#               one pass, and so does a detached checkout with --head at HEAD; each rule fails on
#               its own: uncommitted changes, the wrong or a misnumbered branch, a detached HEAD
#               without --head or another commit than --head, a changed, deleted, or extra file in
#               an existing eval, a file outside the allowed set, a product doc's mode changed, a
#               symlink (a new eval's check.sh, or deeper in it), a submodule, a .gitattributes in
#               a new eval, a CI skip token in the ## Milestone title or HEAD's commit message (each
#               token, any case, and a skip-checks: trailer), no new eval, a new eval without
#               check.sh, changed PRD
#               text, a second ## heading or a misnumbered one, a reused requirement id, a
#               scenario without an eval or an eval without a scenario, a scenario.md that
#               disagrees, no script-judged scenario, a changed Immutable constraints section
#               or other non-Roadmap section of VISION.md, a level-1 or level-2 heading added
#               inside the Roadmap (after a tab or up to 3 spaces, or setext; an indented code
#               line, a ###, and `##x` pass), a Roadmap without the milestone, a
#               grounded milestone that leaves docs/research.md as it is, an ungrounded one that
#               changes it or cites a URL, and a research file the proposal check rejects
#   - bad arguments
#
# Nothing here calls gh or the network. Git config is isolated (GIT_CONFIG_GLOBAL=/dev/null).
# Exits 0 when every check passes, 1 when any fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NEXT="$(cd "$HERE/.." && pwd)/octo-genesis-next.sh"
# shellcheck source=scripts/test/genesis-fixture.sh
source "$HERE/genesis-fixture.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# The helper never reads it; pinned so nothing here depends on running under Actions or not.
export GITHUB_ACTIONS=false

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ✓ $1"; }
no() { fail=$((fail + 1)); echo "  ✗ $1"; }
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    no "$1"; printf '      wanted: %s\n      got:    %s\n' "$2" "$3"; fi
}
bounded() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "genesis-next: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

G() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false \
  "${@:2}"; }
commit() { G "$1" add -A && G "$1" commit -q --no-verify -m "$2"; }

# repo <dir> : a genesis repo on main: the proposal docs and one eval, committed.
repo() {
  genesis_fixture "$1"
  mkdir -p "$1/evals/recall-turn-3"
  printf -- '---\nid: recall-turn-3\njudge: script\nrequirement: R1\n---\n\nRecall.\n' \
    >"$1/evals/recall-turn-3/scenario.md"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$1/evals/recall-turn-3/check.sh"
  git init -q -b main "$1" && commit "$1" init
}
# run <args...> : run the helper; sets out (stdout, lines joined by |) and rc.
run() {
  out="$(bounded 20 bash "$NEXT" "$@" 2>/dev/null)"; rc=$?
  out="$(printf '%s' "$out" | paste -sd '|' -)"
}

echo "• octo-genesis-next.sh --rev"
r="$tmp/r"
repo "$r"
sha="$(git -C "$r" rev-parse HEAD)"
run --rev main "$r"
same "after the MVP: milestone 2, requirement R2" \
  "0|rev: $sha|milestone: 2|next_requirement: R2" "$rc|$out"
printf '\n## Milestone 2: Export\n\n### R2: Export\n\n- x\n\n### R7: More\n\n- y\n' \
  >>"$r/docs/prd.md"
run --rev main "$r"
same "the work tree is not read: still milestone 2" \
  "0|rev: $sha|milestone: 2|next_requirement: R2" "$rc|$out"
commit "$r" m2
sha="$(git -C "$r" rev-parse HEAD)"
run --rev main --tip "$sha" "$r"
same "after ## Milestone 2: milestone 3, after the highest requirement id" \
  "0|rev: $sha|milestone: 3|next_requirement: R8" "$rc|$out"
run --rev main --tip "$(printf '%040d' 1)" "$r"
same "a --tip that is not the rev: FAIL" \
  "1|FAIL: main is $sha, not $(printf '%040d' 1), the commit the evals metric judged" "$rc|$out"
run --rev origin/main "$r"
same "a rev that is not a commit here: FAIL" \
  "1|FAIL: origin/main is not a commit here: fetch it first" "$rc|$out"
git -C "$r" rm -q VISION.md && commit "$r" rm
run --rev main "$r"
same "a rev without VISION.md: not a genesis repo" \
  "1|FAIL: VISION.md is missing at main: not a genesis repo" "$rc|$out"
mkdir -p "$tmp/nogit"
run --rev main "$tmp/nogit"
same "a directory outside git: FAIL" "1|FAIL: $tmp/nogit is not a git work tree" "$rc|$out"

echo "• octo-genesis-next.sh --check"
# [MB=<branch>] [JUDGE=model] milestone <dir> [ungrounded] : on a new branch (milestone-2-export),
# commit a valid milestone: the PRD section, one new script eval (or $JUDGE), a Roadmap item,
# and (grounded) a research refresh.
milestone() {
  local d="$1" mark="" cite=" (https://baz.example/changelog)" j="${JUDGE:-script}"
  G "$d" switch -q -c "${MB:-milestone-2-export}"
  [ "${2:-}" != ungrounded ] || { mark=$'ungrounded: no web access\n\n'; cite=""; }
  cat >>"$d/docs/prd.md" <<MD

## Milestone 2: Export conversations

${mark}Every eval passes; users of similar apps ask to take their history with them${cite}.

### R2: Export a conversation

- The export holds every turn, in order

### Success metrics

- An export of 200 turns round-trips

### Scenarios

#### export-200-turns

- requirement: R2
- judge: $j

Exporting a 200-turn conversation gives every turn back in order.
MD
  mkdir -p "$d/evals/export-200-turns"
  printf -- '---\nid: export-200-turns\njudge: %s\nrequirement: R2\n---\n\nExport.\n' "$j" \
    >"$d/evals/export-200-turns/scenario.md"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$d/evals/export-200-turns/check.sh"
  printf '2. **Milestone 2: Export conversations** — every turn, in order%s\n' "$cite" \
    >>"$d/VISION.md"
  [ "${2:-}" = ungrounded ] \
    || printf -- '- https://baz.example/changelog — Baz changelog, accessed 2026-11-02\n' \
      >>"$d/docs/research.md"
  commit "$d" "feat: milestone 2"
}
n=0
# case_repo : a fresh repo with a valid milestone committed, in $c.
case_repo() { n=$((n + 1)); c="$tmp/c$n"; repo "$c"; milestone "$c" "$@"; }
check() { run --check --base main --branch "${BR:-milestone-2-export}" "$c"; }
# fails <label> <FAIL line> : the check exited 1 and printed that line among its FAIL lines.
fails() {
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | tr '|' '\n' | grep -Fxq -- "FAIL: $2"; then
    ok "$1"; else no "$1"; printf '      wanted: 1 with FAIL: %s\n      got:    %s|%s\n' "$2" \
      "$rc" "$out"; fi
}

case_repo
check
same "a valid grounded milestone passes" "0|ok: milestone 2: export-200-turns" "$rc|$out"
case_repo ungrounded
check
same "a valid ungrounded milestone passes (research unchanged, no URL)" \
  "0|ok: milestone 2: export-200-turns" "$rc|$out"

case_repo
echo draft >"$c/notes.txt"
check
fails "an uncommitted file fails" "the work tree has uncommitted changes: commit them first"
case_repo
BR=milestone-2-other check
fails "another branch name than the current one fails" \
  "the current branch is milestone-2-export, not milestone-2-other"
MB=milestone-3-export case_repo
BR=milestone-3-export check
fails "a misnumbered branch fails" "branch milestone-3-export is not milestone-2-<slug> (lowercase kebab-case)"
MB=milestone-2-Export case_repo
BR=milestone-2-Export check
fails "a branch slug that is not kebab-case fails" \
  "branch milestone-2-Export is not milestone-2-<slug> (lowercase kebab-case)"
slug="$(printf 'abcdefghij-%.0s' 1 2 3 4 5)x"
MB="milestone-2-$slug" case_repo
BR="milestone-2-$slug" check
fails "a slug over 50 characters fails" "branch milestone-2-$slug: the slug is over 50 characters"

# --head: auto's merge-time check runs in a detached checkout of the reviewed commit.
case_repo
head="$(git -C "$c" rev-parse HEAD)"
G "$c" switch -q --detach
run --check --base main --branch milestone-2-export --head "$head" "$c"
same "a detached checkout with --head at HEAD passes" "0|ok: milestone 2: export-200-turns" \
  "$rc|$out"
check
fails "a detached checkout without --head fails" \
  "the current branch is detached, not milestone-2-export"
G "$c" switch -q --detach HEAD~1
run --check --base main --branch milestone-2-export --head "$head" "$c"
same "--head that is not HEAD fails, checking nothing else" \
  "1|FAIL: HEAD is $(git -C "$c" rev-parse HEAD), not $head" "$rc|$out"

case_repo
echo 'exit 0' >>"$c/evals/recall-turn-3/check.sh" && commit "$c" weaken
check
fails "a changed existing eval fails" \
  "evals/recall-turn-3/check.sh: evals/recall-turn-3/ already exists: a milestone never changes an existing eval"
case_repo
G "$c" rm -q evals/recall-turn-3/scenario.md && commit "$c" delete
check
fails "a deleted eval file fails" \
  "evals/recall-turn-3/scenario.md: evals/recall-turn-3/ already exists: a milestone never changes an existing eval"
case_repo
echo input >"$c/evals/recall-turn-3/input.txt" && commit "$c" extra
check
fails "a file added to an existing eval fails" \
  "evals/recall-turn-3/input.txt: evals/recall-turn-3/ already exists: a milestone never changes an existing eval"
case_repo
mkdir -p "$c/src" && echo 'x' >"$c/src/app.ts" && commit "$c" code
check
fails "a file outside the allowed set fails" \
  "src/app.ts: a milestone changes only docs/prd.md, docs/research.md, VISION.md, and new evals/<id>/ directories"
case_repo
echo x >>"$c/GENESIS.md" && commit "$c" genesis
check
fails "GENESIS.md is not one of them" \
  "GENESIS.md: a milestone changes only docs/prd.md, docs/research.md, VISION.md, and new evals/<id>/ directories"
case_repo
echo '# x' >"$c/evals/run.sh" && commit "$c" runner
check
fails "a file directly under evals/ fails" \
  "evals/run.sh: a milestone changes only docs/prd.md, docs/research.md, VISION.md, and new evals/<id>/ directories"
case_repo
chmod +x "$c/docs/prd.md" && commit "$c" mode
check
same "a product doc whose mode changed fails, alone" \
  "1|FAIL: docs/prd.md: its mode changed (100644 to 100755)" "$rc|$out"
case_repo
rm "$c/evals/export-200-turns/check.sh"
ln -s ../recall-turn-3/check.sh "$c/evals/export-200-turns/check.sh" && commit "$c" symlink
check
fails "a new eval's check.sh as a symlink fails" \
  "evals/export-200-turns/check.sh: a symlink: a milestone adds and changes regular files only"
case_repo
mkdir -p "$c/evals/export-200-turns/lib" && ln -s ../../../VISION.md "$c/evals/export-200-turns/lib/v" \
  && commit "$c" symlink2
check
fails "a symlink deeper in a new eval fails" \
  "evals/export-200-turns/lib/v: a symlink: a milestone adds and changes regular files only"
case_repo
G "$c" update-index --add --cacheinfo "160000,$(git -C "$c" rev-parse HEAD),evals/export-200-turns/sub" \
  && G "$c" commit -q --no-verify -m gitlink
check
fails "a submodule in a new eval fails" \
  "evals/export-200-turns/sub: a submodule: a milestone adds and changes regular files only"
case_repo
echo '* -text' >"$c/evals/export-200-turns/.gitattributes" && commit "$c" attrs
check
fails "a .gitattributes in a new eval fails" \
  "evals/export-200-turns/.gitattributes: a .gitattributes changes how git checks out the evals"
case_repo
sed -i.bak 's/^## Milestone 2: Export conversations$/## Milestone 2: Export conversations [Skip CI]/' \
  "$c/docs/prd.md" && rm "$c/docs/prd.md.bak" && commit "$c" title
check
fails "a CI skip token in the ## Milestone title fails, in any case" \
  "docs/prd.md: the ## Milestone 2 title holds a CI skip token: the PR title carries it into the merge commit, so the evals run on the default branch would not start"
for token in '[skip ci]' '[ci skip]' '[NO CI]' '[skip actions]' '[actions skip]' \
    $'\n\nSkip-checks: true'; do
  case_repo
  G "$c" commit -q --amend --no-verify -m "feat: milestone 2 ${token}"
  check
  fails "a CI skip token in HEAD's commit message fails ($(printf '%s' "$token" | tr -d '\n'))" \
    "the HEAD commit message holds a CI skip token: its workflows would not start"
done

case_repo
G "$c" rm -q -r evals/export-200-turns && commit "$c" noeval
check
fails "a milestone without a new eval fails" "no new eval: a milestone adds at least one evals/<id>/"
case_repo
G "$c" rm -q evals/export-200-turns/check.sh && commit "$c" nocheck
check
fails "a new eval without check.sh fails" "evals/export-200-turns/check.sh is missing"

case_repo
sed -i.bak 's/^Chat companions forget earlier conversations\.$/Chat companions remember./' \
  "$c/docs/prd.md" && rm "$c/docs/prd.md.bak" && commit "$c" reword
check
fails "changed PRD text fails" "docs/prd.md: existing text changed: a milestone only appends its section"
case_repo
printf '\n## Milestone 3: More\n' >>"$c/docs/prd.md" && commit "$c" two
check
fails "a second ## heading fails" \
  "docs/prd.md: append one ## Milestone 2 section, no other ## heading (\"## Milestone 3: More\")"
case_repo
sed -i.bak 's/^## Milestone 2: Export/## Milestone 3: Export/' "$c/docs/prd.md" \
  && rm "$c/docs/prd.md.bak" && commit "$c" renumber
check
fails "a misnumbered section fails" \
  "docs/prd.md: the appended section must open with '## Milestone 2: <title>'"
case_repo
sed -i.bak 's/^### R2: Export/### R1: Export/; s/^- requirement: R2$/- requirement: R1/' \
  "$c/docs/prd.md" && rm "$c/docs/prd.md.bak" && commit "$c" reuse
check
fails "a reused requirement id fails" \
  "docs/prd.md: ## Milestone 2: requirement R1 is not new: number it after the PRD's"
case_repo
printf '\n#### orphan\n\n- requirement: R2\n- judge: script\n\nNo eval.\n' >>"$c/docs/prd.md" \
  && commit "$c" orphan
check
fails "a scenario without a new eval fails" \
  "docs/prd.md: ## Milestone 2: scenario orphan has no new evals/orphan/"
case_repo
mkdir -p "$c/evals/lonely" && cp "$c/evals/export-200-turns/check.sh" "$c/evals/lonely/" \
  && printf -- '---\nid: lonely\njudge: script\nrequirement: R2\n---\n\nx\n' \
    >"$c/evals/lonely/scenario.md" && commit "$c" lonely
check
fails "a new eval without a scenario fails" \
  "docs/prd.md: ## Milestone 2: evals/lonely/ has no #### lonely scenario"
case_repo
sed -i.bak 's/^judge: script$/judge: model/' "$c/evals/export-200-turns/scenario.md" \
  && rm "$c/evals/export-200-turns/scenario.md.bak" && commit "$c" judge
check
fails "a scenario.md that disagrees with its scenario fails" \
  "evals/export-200-turns/scenario.md: its front matter needs id: export-200-turns, judge: script, and requirement: R2, as its #### export-200-turns scenario says"
JUDGE=model case_repo
check
fails "a milestone with no script-judged scenario fails" \
  "docs/prd.md: ## Milestone 2: needs at least one scenario with '- judge: script'"

case_repo
sed -i.bak 's/^- Conversation history never leaves.*/- Anything goes./' "$c/VISION.md" \
  && rm "$c/VISION.md.bak" && commit "$c" immutable
check
fails "a changed Immutable constraints section fails" \
  "VISION.md: ## Immutable constraints changed: only a human edits that section"
case_repo
sed -i.bak 's/^A companion that remembers you\.$/A companion./' "$c/VISION.md" \
  && rm "$c/VISION.md.bak" && commit "$c" goal
check
fails "a change outside ## Roadmap fails" "VISION.md: only ## Roadmap may change"
case_repo
sed -i.bak 's/^2\. \*\*Milestone 2: /2. **Next: /' "$c/VISION.md" && rm "$c/VISION.md.bak" \
  && commit "$c" roadmap
check
fails "a Roadmap without the milestone fails" "VISION.md: ## Roadmap needs an item for Milestone 2"
# Inside ## Roadmap, so the section checks pass them; CommonMark still reads each as a heading.
for h in $'##\tImmutable constraints' ' ## Immutable constraints' '   # Vision' '##' \
    $'Immutable constraints\n---'; do
  case_repo
  printf '\n%s\n\n- New constraint\n' "$h" >>"$c/VISION.md" && commit "$c" heading
  check
  fails "a Roadmap line that is a heading ('$(printf '%s' "${h//$'\t'/<tab>}" | paste -sd '/' -)') fails" \
    "VISION.md: its level-1 or level-2 headings changed: only a human adds, removes, or renames one (a Roadmap change adds items, not headings)"
done
# The check runs in auto's merge gate under the user's git config, so forced diff color or an
# external diff must not blind it.
case_repo
printf '\n## Immutable constraints\n\n- New constraint\n' >>"$c/VISION.md" && commit "$c" heading
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=color.ui GIT_CONFIG_VALUE_0=always \
  GIT_CONFIG_KEY_1=diff.external GIT_CONFIG_VALUE_1=true check
fails "a Roadmap heading still fails with color.ui=always and diff.external set" \
  "VISION.md: its level-1 or level-2 headings changed: only a human adds, removes, or renames one (a Roadmap change adds items, not headings)"
for h in '    ## code, not a heading' '### Sub-item' '##not a heading'; do
  case_repo
  printf '\n%s\n' "$h" >>"$c/VISION.md" && commit "$c" nonheading
  check
  same "a Roadmap line that is not a level-1 or level-2 heading ('$h') passes" \
    "0|ok: milestone 2: export-200-turns" "$rc|$out"
done

case_repo
G "$c" checkout -q main -- docs/research.md && commit "$c" unresearched
check
fails "a grounded milestone that leaves research as it is fails" \
  "docs/research.md: a grounded milestone refreshes it with what it read (or mark the section 'ungrounded: no web access')"
case_repo ungrounded
echo '- https://x.example — x, accessed 2026-11-02' >>"$c/docs/research.md" && commit "$c" r
check
fails "an ungrounded milestone that changes research fails" \
  "docs/research.md: an ungrounded milestone read no source, so it leaves the file as it is"
case_repo ungrounded
printf '\nSee https://x.example.\n' >>"$c/docs/prd.md" && commit "$c" url
check
fails "an ungrounded milestone that cites a URL in the PRD fails" \
  "docs/prd.md: an ungrounded milestone read no source, so its section cites no URL"
case_repo ungrounded
printf '   See https://x.example.\n' >>"$c/VISION.md" && commit "$c" vurl
check
fails "an ungrounded milestone that cites a URL in VISION.md fails" \
  "VISION.md: an ungrounded milestone read no source, so it cites no URL"
case_repo
printf -- '- not a source\n' >>"$c/docs/research.md" && commit "$c" badsource
check
fails "research the proposal check rejects fails" \
  "docs/research.md: 1 ## Sources item(s) are not '- <URL> … accessed YYYY-MM-DD'"

echo "• bad arguments"
for args in "" "--rev main" "--check --base main $c" "--check --branch b $c" \
    "--rev main --tip abc $c" "--rev main --check --base main --branch b $c" "--bogus $c" \
    "--check --base main --branch b --head abc $c" "--rev main --head $(printf '%040d' 1) $c" \
    "--rev main $tmp/missing"; do
  # shellcheck disable=SC2086 # each case is several words on purpose
  out="$(bounded 10 bash "$NEXT" $args 2>/dev/null)"; rc=$?
  same "bad arguments (${args:-none}) exit 2" "2|" "$rc|$out"
done

echo
echo "genesis-next: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
