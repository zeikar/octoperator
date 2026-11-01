#!/usr/bin/env bash
# octo-genesis-check.sh — check a genesis folder, before a run (--preflight) or its proposal.
#
# Usage:
#   octo-genesis-check.sh DIR
#   octo-genesis-check.sh --preflight DIR
#
# DIR alone checks the proposal genesis wrote into DIR (formats:
# skills/genesis/references/proposal.md):
#   - GENESIS.md opens with front matter holding a non-empty `sentence`, `repo` as OWNER/NAME,
#     and `visibility` as private or public.
#   - docs/research.md has the sections ## Problem, ## Prior art, ## Build, ## Skip, and
#     ## Sources. Prior art has a Name | Kind | URL | License | Strengths | Gaps table whose
#     rows have a kind of service or OSS and an http(s) URL. Build and Skip have at least one
#     `- ` item each. Each Sources item is `- <URL> … accessed YYYY-MM-DD`. Grounded, Prior
#     art has at least one row, every Build item cites a URL (Skip items may), and Sources has
#     at least one item. Ungrounded (the line `ungrounded: no web access` before ## Problem),
#     Prior art has no rows, Sources no items, and the file no http(s) URL. A line that looks
#     like a misspelled marker is reported.
#
# --preflight checks DIR before genesis writes anything: it is outside any git work tree, it
# holds nothing but a `.claude/` directory, and its name is a valid GitHub repo name (letters,
# digits, `.`, `-`, `_`). On success it prints DIR's absolute path.
#
# Offline: --preflight runs one local `git rev-parse`; neither mode calls gh or touches the
# network.
#
# Exit codes: 0 valid, 1 one `FAIL: <problem>` line printed per problem, 2 bad arguments or
# DIR is not a directory, 3 git could not check DIR (git's output on stderr).
set -euo pipefail
# Bracket ranges like A-Z then match ASCII only, as GitHub's repo names do, in every locale, and
# git prints its messages untranslated, so --preflight can match them.
export LC_ALL=C

PREFLIGHT=0 DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --preflight) PREFLIGHT=1; shift ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$DIR" ] || { echo "Only one DIR may be given" >&2; exit 2; }
       DIR="$1"; shift ;;
  esac
done

[ -n "$DIR" ] || { echo "Usage: octo-genesis-check.sh [--preflight] DIR" >&2; exit 2; }
[ -d "$DIR" ] || { echo "Not a directory: $DIR" >&2; exit 2; }
ABS="$(cd "$DIR" && pwd)" || { echo "Cannot enter: $DIR" >&2; exit 2; }

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

# How many unexpected entries --preflight names before summing up the rest.
SHOW_MAX=5

# git_check : FAIL when DIR is inside a git work tree. Exits 3 when git cannot tell (git missing,
# a "dubious ownership" refusal, …).
git_check() {
  local out rc=0
  out="$(git -C "$ABS" rev-parse --is-inside-work-tree 2>&1)" || rc=$?
  case "$rc:$out" in
    0:*) fail "directory is inside a git work tree" ;;
    128:*"not a git repository"*) ;;
    *) printf 'git rev-parse failed (exit %s): %s\n' "$rc" "$out" >&2; exit 3 ;;
  esac
}

preflight() {
  local p e extra=0
  git_check
  case "${ABS##*/}" in
    '' | *[!A-Za-z0-9._-]*)
      fail "directory name '${ABS##*/}' is not a valid repo name (use letters, digits, . - _)" ;;
  esac
  shopt -s nullglob dotglob
  for p in "$ABS"/*; do
    e="${p##*/}"
    case "$e" in . | ..) continue ;; esac
    if [ "$e" = .claude ] && [ -d "$p" ]; then continue; fi
    extra=$((extra + 1))
    [ "$extra" -gt "$SHOW_MAX" ] || fail "directory not empty: $e"
  done
  shopt -u nullglob dotglob
  [ "$extra" -le "$SHOW_MAX" ] || fail "directory not empty: and $((extra - SHOW_MAX)) more"
}

# front_matter <file> : prints the lines between a first-line `---` and the next `---`; exits 1
# when the file does not open with front matter or it never closes.
front_matter() {
  awk 'NR == 1 { if ($0 != "---") exit 1; next }
       $0 == "---" { closed = 1; exit }
       { print }
       END { exit !closed }' "$1"
}

# fm_value <front-matter> <key> : prints the key's inline value, trimmed (empty when the key is
# missing or has no inline value).
fm_value() {
  printf '%s\n' "$1" | awk -v k="$2" 'index($0, k ":") == 1 {
    v = substr($0, length(k) + 2); gsub(/^[ \t]+|[ \t\r]+$/, "", v); print v; exit }'
}

# fm_has_sentence <front-matter> : exits 0 when `sentence` has a non-empty value, inline or as a
# `|` / `>` block scalar followed by an indented line.
fm_has_sentence() {
  printf '%s\n' "$1" | awk '
    block { if ($0 ~ /^[ \t]+[^ \t]/) ok = 1; exit }
    index($0, "sentence:") == 1 {
      v = substr($0, 10); gsub(/^[ \t]+|[ \t\r]+$/, "", v)
      if (v ~ /^[|>][-+]?$/) { block = 1; next }
      if (v != "" && v != "\"\"" && v != "'\'''\''") ok = 1
      exit }
    END { exit !ok }'
}

check_genesis_md() {
  local f="$ABS/GENESIS.md" fm repo vis
  [ -f "$f" ] || { fail "GENESIS.md is missing"; return 0; }
  if ! fm="$(front_matter "$f")"; then
    fail "GENESIS.md: no front matter (--- … --- at the top)"
    return 0
  fi
  fm_has_sentence "$fm" || fail "GENESIS.md: front matter needs a non-empty sentence"
  repo="$(fm_value "$fm" repo)"
  if ! printf '%s\n' "$repo" | grep -Eqx '[A-Za-z0-9_-]+/[A-Za-z0-9._-]+'; then
    fail "GENESIS.md: front matter needs repo as OWNER/NAME (got '$repo')"
  fi
  vis="$(fm_value "$fm" visibility)"
  case "$vis" in
    private | public) ;;
    *) fail "GENESIS.md: front matter needs visibility: private or public (got '$vis')" ;;
  esac
}

# section <file> <heading> : prints the lines under `## <heading>` up to the next `## ` heading;
# exits 1 when the heading is missing.
section() {
  awk -v h="## $2" '{ line = $0; sub(/[ \t\r]+$/, "", line) }
    line == h { on = 1; found = 1; next }
    on && /^## / { exit }
    on { print }
    END { exit !found }' "$1"
}

# items <text> : prints the text's top-level `- ` list items.
items() { printf '%s\n' "$1" | grep -E '^- ' || true; }

check_research_md() {
  local f="$ABS/docs/research.md" grounded=1 s body missing=0 n url
  local problem="" prior="" build="" skip="" sources=""
  [ -f "$f" ] || { fail "docs/research.md is missing"; return 0; }
  # The marker counts only above ## Problem; a misplaced or misspelled one is reported, and the
  # file is checked as grounded. Misspelled: no exact marker, but a line above ## Problem that
  # mentions "ungrounded", or one anywhere that also mentions "web access".
  case "$(awk '{ line = $0; sub(/[ \t\r]+$/, "", line); low = tolower(line) }
               line == "## Problem" { above = 1 }
               line == "ungrounded: no web access" {
                 print (above ? "late" : "early"); found = 1; exit }
               index(low, "ungrounded") && (!above || index(low, "web access")) { near = 1 }
               END { if (!found && near) print "near" }' \
            "$f")" in
    early) grounded=0 ;;
    late) fail "docs/research.md: the line 'ungrounded: no web access' must come" \
            "before ## Problem" ;;
    near) fail "docs/research.md: write the marker exactly as the line" \
            "'ungrounded: no web access'" ;;
  esac
  for s in Problem 'Prior art' Build Skip Sources; do
    if body="$(section "$f" "$s")"; then
      case "$s" in
        Problem) problem="$body" ;;
        'Prior art') prior="$body" ;;
        Build) build="$body" ;;
        Skip) skip="$body" ;;
        Sources) sources="$body" ;;
      esac
    else
      fail "docs/research.md: missing section ## $s"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || return 0

  printf '%s\n' "$problem" | grep -q '[^[:space:]]' \
    || fail "docs/research.md: ## Problem is empty"

  # Prior art: the header row, then each data row's kind and URL.
  body="$(printf '%s\n' "$prior" | awk -F'|' -v grounded="$grounded" '
    function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
    !/^\|/ { next }
    !seen { seen = 1; h = tolower($0); gsub(/[ \t\r]/, "", h)
            if (h != "|name|kind|url|license|strengths|gaps|") bad = 1
            next }
    # With the wrong columns, the cells below mean nothing: report the header alone.
    bad || /^\|[ \t:|-]*$/ { next }
    { rows++
      k = tolower(trim($3))
      if (k != "service" && k != "oss")
        print "FAIL: docs/research.md: prior-art row \"" trim($2) "\" needs kind service or OSS"
      if (trim($4) !~ /^<?https?:\/\//)
        print "FAIL: docs/research.md: prior-art row \"" trim($2) "\" needs an http(s) URL" }
    END { if (!seen || bad)
            print "FAIL: docs/research.md: ## Prior art needs a table with columns " \
                  "Name | Kind | URL | License | Strengths | Gaps"
          else if (grounded && !rows)
            print "FAIL: docs/research.md: ## Prior art has no rows"
          else if (!grounded && rows)
            print "FAIL: docs/research.md: ungrounded, but ## Prior art has " rows " row(s)" }')"
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
    FAILS=$((FAILS + $(printf '%s\n' "$body" | grep -c '')))
  fi

  # An http(s) URL: the scheme and at least one host character, so "http:// to https://" in
  # prose is not one.
  url='https\{0,1\}://[^[:space:]<>()|]'
  # Only Build items must cite a URL; a Skip item needs its reason, and may cite one.
  for s in Build Skip; do
    if [ "$s" = Build ]; then body="$(items "$build")"; else body="$(items "$skip")"; fi
    if [ -z "$body" ]; then
      fail "docs/research.md: ## $s needs at least one '- ' item"
    elif [ "$s" = Build ] && [ "$grounded" -eq 1 ]; then
      n="$(printf '%s\n' "$body" | grep -cv "$url" || true)"
      [ "$n" -eq 0 ] || fail "docs/research.md: $n ## Build item(s) cite no URL"
    fi
  done

  body="$(items "$sources")"
  if [ "$grounded" -eq 0 ]; then
    # An ungrounded run read nothing, so any source or URL in the file was made up.
    n="$(printf '%s' "$body" | grep -c '' || true)"
    [ "$n" -eq 0 ] || fail "docs/research.md: ungrounded, but ## Sources has $n item(s)"
    n="$(grep -c "$url" "$f" || true)"
    [ "$n" -eq 0 ] || fail "docs/research.md: ungrounded, but $n line(s) cite an http(s) URL"
  elif [ -z "$body" ]; then
    fail "docs/research.md: ## Sources has no items"
  else
    n="$(printf '%s\n' "$body" \
      | grep -cvE '^- <?https?://[^ >]+>?.*accessed [0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
    [ "$n" -eq 0 ] \
      || fail "docs/research.md: $n ## Sources item(s) are not '- <URL> … accessed YYYY-MM-DD'"
  fi
}

if [ "$PREFLIGHT" -eq 1 ]; then
  preflight
  [ "$FAILS" -eq 0 ] || exit 1
  printf '%s\n' "$ABS"
  exit 0
fi

# One check per proposal file. A stage that adds a file adds its check here.
check_genesis_md
check_research_md

[ "$FAILS" -eq 0 ] || exit 1
