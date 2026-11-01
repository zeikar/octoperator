#!/usr/bin/env bash
# octo-genesis-plan.sh — work out where `genesis --approve` resumes, and print its ordered steps.
#
# Usage:
#   octo-genesis-plan.sh DIR
#
# DIR is the genesis proposal folder. The helper runs `octo-genesis-check.sh --values DIR` (the
# proposal check) first, then works out the stage from DIR's git state:
#   scaffold  DIR is outside any git work tree: write the skeleton, test, git init, commit, then
#             create
#   commit    DIR is a work tree's top level with nothing committed: as scaffold, without init
#   create    a commit and no origin: preflight, name check, gh repo create --push, then setup
#   push      origin is GENESIS.md's repo, but HEAD has no upstream there: preflight, git push,
#             then setup
#   setup     origin is GENESIS.md's repo and HEAD is pushed: preflight, then setup's steps
#
# It prints `dir:`, `repo:`, and `stage:` lines, then one numbered step per line, in run order.
# A step that starts with `write ` is a file to write (skills/genesis/references/skeleton.md);
# every other step is one plain command to run as printed, except that `<the skeleton's other
# files>` in `git add` stands for the skeleton's module, test, and any stack manifest its
# `test_command` needs. Visibility is --private unless GENESIS.md says `visibility: public`. The
# gh repo create description is the sentence on one line, its control characters made spaces,
# cut to GitHub's 350-character limit, and single-quoted.
#
# origin counts as GENESIS.md's repo only when every URL git fetches from and pushes to (`git
# remote get-url`, so a pushurl and insteadOf rewrites count) is a github.com URL of that repo.
#
# Read-only and offline: it reads DIR's files and git state; it never calls gh or writes.
#
# Exit codes: 0 plan printed, 1 one `FAIL: <problem>` line per problem (the proposal check's, or
# `FAIL: git: …` for DIR's git state), 2 bad arguments or DIR is not a directory, 3 git could not
# check DIR (git's output on stderr).
set -euo pipefail
# Byte-wise string handling for the description cut, and untranslated git messages.
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$DIR" ] || { echo "Only one DIR may be given" >&2; exit 2; }
       DIR="$1"; shift ;;
  esac
done
[ -n "$DIR" ] || { echo "Usage: octo-genesis-plan.sh DIR" >&2; exit 2; }

# GitHub rejects a repo description longer than this.
DESC_MAX=350

rc=0
values="$(bash "$HERE/octo-genesis-check.sh" --values "$DIR")" || rc=$?
case "$rc" in
  0) ;;
  1) printf '%s\n' "$values"; exit 1 ;;
  *) exit 2 ;;
esac
value() { printf '%s\n' "$values" | sed -n "s/^$1: //p"; }
REPO="$(value repo)" VIS="$(value visibility)" CMD="$(value test_command)"
TEST_FILE="$(value test_file)" SENTENCE="$(value sentence)"
ABS="$(cd "$DIR" && pwd)"
PHYS="$(cd "$DIR" && pwd -P)"

# git_out <args...> : runs `git -C DIR <args>`; sets OUT (stdout and stderr) and RC.
git_out() { RC=0; OUT="$(git -C "$ABS" "$@" 2>&1)" || RC=$?; }

# url_repo <url> : prints the owner/name a github.com remote URL points to, lowercased, or
# nothing for any other URL. Only the exact https://, ssh://git@, and git@github.com: forms
# count, with an optional `.git` and trailing `/`: another host or path is another repo.
url_repo() {
  local re='^(https://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/]+)/([^/]+)/?$'
  [[ "$1" =~ $re ]] || return 0
  printf '%s/%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]%.git}" | tr '[:upper:]' '[:lower:]'
}

git_out rev-parse --show-toplevel
case "$RC:$OUT" in
  0:*)
    if [ "$OUT" != "$PHYS" ]; then
      echo "FAIL: git: $ABS is inside the git work tree $OUT; run genesis in its own folder"
      exit 1
    fi
    git_out rev-parse --verify --quiet 'HEAD^{commit}'
    COMMITTED=$(( RC == 0 ))
    git_out remote get-url --all origin
    case "$RC:$OUT" in
      0:*) URLS="$OUT" ;;
      2:*"No such remote"*) URLS="" ;;
      *) printf 'git remote get-url failed (exit %s): %s\n' "$RC" "$OUT" >&2; exit 3 ;;
    esac
    if [ -n "$URLS" ]; then
      git_out remote get-url --push --all origin
      [ "$RC" -eq 0 ] || { printf 'git remote get-url --push failed (exit %s): %s\n' "$RC" \
        "$OUT" >&2; exit 3; }
      want="$(printf '%s\n' "$REPO" | tr '[:upper:]' '[:lower:]')"
      while IFS= read -r u; do
        [ "$(url_repo "$u")" = "$want" ] \
          || { echo "FAIL: git: origin is $u, not GENESIS.md's repo $REPO"; exit 1; }
      done <<EOF
$URLS
$OUT
EOF
    fi
    if [ -z "$URLS" ]; then
      if [ "$COMMITTED" -eq 1 ]; then STAGE=create; else STAGE=commit; fi
    elif [ "$COMMITTED" -eq 0 ]; then
      echo "FAIL: git: origin is set, but nothing is committed; commit, or remove origin"
      exit 1
    else
      git_out rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
      case "$RC:$OUT" in
        0:origin/*) STAGE=setup ;;
        *) STAGE=push ;;
      esac
    fi ;;
  128:*"not a git repository"*) STAGE=scaffold ;;
  *) printf 'git rev-parse failed (exit %s): %s\n' "$RC" "$OUT" >&2; exit 3 ;;
esac

# q <word> : prints the word as-is when it is shell-safe, else single-quoted.
q() {
  case "$1" in
    '' | *[!A-Za-z0-9_./:@%+=,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# description <text> : the text on one line, control characters made spaces and runs of spaces
# squeezed, cut to DESC_MAX bytes (so never over DESC_MAX characters) with `...`, never inside a
# UTF-8 character.
description() {
  local s i b need
  s="$(printf '%s' "$1" | tr '\001-\037\177' ' ' | tr -s ' ')"
  s="${s# }" s="${s% }"
  if [ "${#s}" -gt "$DESC_MAX" ]; then
    s="${s:0:$((DESC_MAX - 3))}"
    # Drop a character the cut split: find its lead byte among the last three bytes.
    for i in 1 2 3; do
      [ "${#s}" -ge "$i" ] || break
      b="${s:$((${#s} - i)):1}"
      case "$b" in
        [$'\x80'-$'\xbf']) continue ;;
        [$'\xc0'-$'\xdf']) need=2 ;;
        [$'\xe0'-$'\xef']) need=3 ;;
        [$'\xf0'-$'\xf7']) need=4 ;;
        *) break ;;
      esac
      [ "$i" -ge "$need" ] || s="${s:0:$((${#s} - i))}"
      break
    done
    s="${s% }..."
  fi
  printf '%s' "$s"
}

N=0
step() { N=$((N + 1)); printf '%s. %s\n' "$N" "$*"; }
D="$(q "$ABS")"

printf 'dir: %s\nrepo: %s\nstage: %s\n' "$ABS" "$REPO" "$STAGE"
case "$STAGE" in
  scaffold | commit)
    step "write the skeleton for \`$CMD\` (skills/genesis/references/skeleton.md): only the" \
      "files that are missing"
    step "bash $(q "$HERE/octo-genesis-check.sh") --skeleton $D"
    step "$CMD"
    [ "$STAGE" = commit ] || step "git -C $D init -b main"
    step "git -C $D add -- GENESIS.md VISION.md docs/research.md docs/prd.md" \
      "docs/adr/0001-stack.md README.md .gitignore .github/workflows/ci.yml $TEST_FILE" \
      "<the skeleton's other files>"
    step "git -C $D commit -m 'chore: scaffold from genesis'" ;;
esac
step "gh auth status"
step "gh api graphql -f query='{viewer{login}}'"
case "$STAGE" in
  scaffold | commit | create)
    DESC="$(description "$SENTENCE")"
    step "gh repo view $REPO --json nameWithOwner"
    step "gh repo create $REPO --$VIS --source $D --remote origin --push" \
      "--description=$(q "$DESC")" ;;
  push) step "git -C $D push -u origin HEAD" ;;
esac
step "bash $(q "$HERE/octo-setup.sh") --repo $REPO"
step "write $ABS/.claude/octoperator.local.md (skeleton.md → Settings): only if it is missing"
# The labels of the cookbook's "Ensure labels exist" recipe
# (skills/github-conventions/references/gh-cli-cookbook.md); change both together.
for l in 'epic 6f42c1 Large body of work' 'feature 0e8a16 New capability' 'bug d73a4a Defect' \
    'chore fbca04 Maintenance' 'docs 0075ca Documentation'; do
  rest="${l#* }"
  step "gh label create ${l%% *} --repo $REPO --color ${rest%% *}" \
    "--description $(q "${rest#* }") --force"
done
for l in p0 p1 p2 p3; do step "gh label create $l --repo $REPO --color ededed --force"; done
