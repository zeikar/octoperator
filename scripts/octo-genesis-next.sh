#!/usr/bin/env bash
# octo-genesis-next.sh — the offline half of `genesis --next`: number the next milestone, and
# check the milestone a run committed before it is pushed (skills/genesis/references/next.md).
#
# Usage:
#   octo-genesis-next.sh --rev REV [--tip SHA] DIR
#   octo-genesis-next.sh --check --base REV --branch NAME [--head SHA] DIR
#
# DIR is a git work tree of a repo genesis created.
#
# --rev reads the product docs at REV (origin/<default branch>) from git's objects, never the
# work tree: GENESIS.md, VISION.md, docs/prd.md, and docs/research.md must exist there. With
# --tip, REV must be that commit (the one the evals metric judged). Prints:
#   rev: <REV's commit>
#   milestone: <n>           1 + the highest `## Milestone <k>` heading in docs/prd.md, and at
#                            least 2: the MVP is milestone 1 (VISION.md's Roadmap item 1)
#   next_requirement: R<k>   1 + the highest `### R<k>:` requirement id in docs/prd.md
#
# --check checks what HEAD committed since its merge base with --base:
#   - the work tree is clean, and the current branch is NAME; with --head (a detached checkout,
#     such as auto's at the reviewed commit), HEAD is SHA instead. NAME is
#     `milestone-<n>-<slug>`: <n> as --rev numbers it at the merge base, <slug> lowercase
#     kebab-case of at most 50 characters;
#   - each change is docs/prd.md or VISION.md modified (both required), docs/research.md
#     modified, each keeping its file mode, or a file added under evals/<id>/ for a lowercase
#     kebab-case <id> that has no evals/<id>/ at the merge base; at least one such new eval, each
#     with scenario.md and check.sh. Nothing else: no other file, deletion, or rename, no
#     existing eval, no symlink or submodule, and no .gitattributes in a new eval;
#   - no CI skip token (`[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]`, `[actions skip]`,
#     or `skip-checks:`, in any case) in the ## Milestone title, which the PR title and so the
#     merge commit carry, or in HEAD's commit message: the default branch's evals run must start;
#   - docs/prd.md only grows: the merge base's file is a prefix of HEAD's, and the appended text
#     is one `## Milestone <n>: <title>` section, with no other `## ` heading, holding
#     `### R<k>: <title>` requirements (ids new to the PRD, each with `- ` acceptance criteria),
#     `### Success metrics` (`- ` items), and `### Scenarios`: one `#### <id>` per new eval, with
#     `- requirement: R<k>` naming one of the section's requirements, `- judge: script` or
#     `- judge: model`, and text, at least one judged by script; each new eval's scenario.md
#     front matter has the same `id:`, `judge:`, and `requirement:` lines;
#   - VISION.md changes only inside ## Roadmap, so ## Immutable constraints never changes, it
#     gains no level-1 or level-2 heading (CommonMark's ATX or setext form), and its Roadmap
#     names `Milestone <n>`: octo-vision-guard.sh --milestone <n>, the guard auto runs on every
#     PR, checks these;
#   - grounding: when the new section holds the line `ungrounded: no web access` before its
#     first `### ` heading, docs/research.md is unchanged, and neither the section nor the lines
#     VISION.md gained cite an http(s) URL; otherwise docs/research.md changed (refreshed);
#   - the product docs still pass the proposal check (octo-genesis-check.sh DIR).
# Prints one `FAIL: <problem>` line per problem, or `ok: milestone <n>: <new eval ids>`.
#
# Offline: git only, never gh; writes nothing.
#
# Exit codes: 0 ok (or --rev's lines), 1 `FAIL:` lines, 2 bad arguments or DIR is not a
# directory, 3 git failed unexpectedly (its output on stderr).
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
MODE=rev DIR="" REV="" TIP="" BASE="" BRANCH="" HEADSHA=""
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --rev) need_value "$@"; REV="$2"; shift 2 ;;
    --tip) need_value "$@"; TIP="$2"; shift 2 ;;
    --check) MODE=check; shift ;;
    --base) need_value "$@"; BASE="$2"; shift 2 ;;
    --branch) need_value "$@"; BRANCH="$2"; shift 2 ;;
    --head) need_value "$@"; HEADSHA="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$DIR" ] || { echo "Only one DIR may be given" >&2; exit 2; }
       DIR="$1"; shift ;;
  esac
done
usage() {
  echo "Usage: octo-genesis-next.sh --rev REV [--tip SHA] DIR" >&2
  echo "       octo-genesis-next.sh --check --base REV --branch NAME [--head SHA] DIR" >&2
  exit 2
}
[ -n "$DIR" ] || usage
if [ "$MODE" = rev ]; then
  [ -n "$REV" ] && [ -z "$BASE$BRANCH$HEADSHA" ] || usage
  [ -z "$TIP" ] || [[ "$TIP" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "--tip must be a 40-digit commit" >&2; exit 2; }
else
  [ -n "$BASE" ] && [ -n "$BRANCH" ] && [ -z "$REV$TIP" ] || usage
  [ -z "$HEADSHA" ] || [[ "$HEADSHA" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "--head must be a 40-digit commit" >&2; exit 2; }
fi
[ -d "$DIR" ] || { echo "Not a directory: $DIR" >&2; exit 2; }

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
g() { git -C "$DIR" "$@"; }
tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "mktemp failed" >&2; exit 3; }
trap 'rm -rf "$tmp"' EXIT

# milestone_number <prd-file> : 1 + the highest `## Milestone <k>` heading, at least 2.
milestone_number() {
  awk '{ sub(/[ \t\r]+$/, "") }
       /^## Milestone [0-9]+(:|$)/ { k = $3; sub(/:.*/, "", k); if (k + 0 > max) max = k + 0 }
       END { print (max < 1 ? 2 : max + 1) }' "$1"
}
# requirement_ids <prd-file> : every `### R<k>:` id in the file, one per line.
requirement_ids() { sed -n 's/^### \(R[0-9][0-9]*\):.*/\1/p' "$1"; }

g rev-parse --is-inside-work-tree >/dev/null 2>&1 || { fail "$DIR is not a git work tree"; exit 1; }

if [ "$MODE" = rev ]; then
  sha="$(g rev-parse --verify -q "$REV^{commit}")" \
    || { fail "$REV is not a commit here: fetch it first"; exit 1; }
  [ -z "$TIP" ] || [ "$sha" = "$TIP" ] \
    || { fail "$REV is $sha, not $TIP, the commit the evals metric judged"; exit 1; }
  for f in GENESIS.md VISION.md docs/prd.md docs/research.md; do
    g cat-file -e "$sha:$f" 2>/dev/null || fail "$f is missing at $REV: not a genesis repo"
  done
  [ "$FAILS" -eq 0 ] || exit 1
  g show "$sha:docs/prd.md" >"$tmp/prd" || exit 3
  next="$(requirement_ids "$tmp/prd" | sed 's/^R//' | sort -n | tail -n 1)"
  printf 'rev: %s\nmilestone: %s\nnext_requirement: R%s\n' \
    "$sha" "$(milestone_number "$tmp/prd")" "$(( ${next:-0} + 1 ))"
  exit 0
fi

# --check
# GitHub's skip tokens: a push whose head commit message holds one starts no workflow.
SKIP_RE='\[(skip ci|ci skip|no ci|skip actions|actions skip)\]|skip-checks:'
mb="$(g merge-base "$BASE" HEAD)" || { echo "git merge-base $BASE HEAD failed" >&2; exit 3; }
[ -z "$(g status --porcelain)" ] || fail "the work tree has uncommitted changes: commit them first"
if [ -n "$HEADSHA" ]; then
  cur="$(g rev-parse -q --verify HEAD)"
  [ "$cur" = "$HEADSHA" ] || { fail "HEAD is ${cur:-unborn}, not $HEADSHA"; exit 1; }
else
  cur="$(g symbolic-ref --short -q HEAD || true)"
  [ "$cur" = "$BRANCH" ] || fail "the current branch is ${cur:-detached}, not $BRANCH"
fi
for f in docs/prd.md VISION.md; do
  g cat-file -e "$mb:$f" 2>/dev/null || { fail "$f is missing at the merge base"; exit 1; }
done
g show "$mb:docs/prd.md" >"$tmp/prd.base" || exit 3
N="$(milestone_number "$tmp/prd.base")"
if [[ "$BRANCH" =~ ^milestone-${N}-([a-z0-9]+(-[a-z0-9]+)*)$ ]]; then
  [ "${#BASH_REMATCH[1]}" -le 50 ] || fail "branch $BRANCH: the slug is over 50 characters"
else
  fail "branch $BRANCH is not milestone-$N-<slug> (lowercase kebab-case)"
fi

# The changed paths, as evals/guard.sh reads them: `:<old mode> <new mode> <old sha> <new sha>
# <status>` NUL `<path>` NUL. --name-status would hide the modes.
g diff --no-color --no-renames --no-ext-diff --no-textconv --raw -z "$mb" HEAD >"$tmp/diff" \
  || exit 3
prd=0 vision=0 research=0 new_ids=""
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  st="${meta##* }" smode="${meta#:}" smode="${smode%% *}" dmode="${meta#* }" dmode="${dmode%% *}"
  case "$dmode" in
    120000) fail "$path: a symlink: a milestone adds and changes regular files only"; continue ;;
    160000) fail "$path: a submodule: a milestone adds and changes regular files only"; continue ;;
  esac
  case "$path" in
    docs/prd.md | VISION.md | docs/research.md)
      [ "$st" = M ] || { fail "$path: may only be modified (status $st)"; continue; }
      case "$path" in docs/prd.md) prd=1 ;; VISION.md) vision=1 ;; *) research=1 ;; esac
      # The vision guard below reports VISION.md's own mode change.
      [ "$smode" = "$dmode" ] || [ "$path" = VISION.md ] \
        || fail "$path: its mode changed ($smode to $dmode)" ;;
    evals/*/*)
      id="${path#evals/}" id="${id%%/*}"
      if ! [[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
        fail "$path: an eval id is lowercase kebab-case"
      elif g cat-file -e "$mb:evals/$id" 2>/dev/null; then
        fail "$path: evals/$id/ already exists: a milestone never changes an existing eval"
      elif [ "$st" != A ]; then
        fail "$path: a new eval's files are only added (status $st)"
      elif [ "${path##*/}" = .gitattributes ]; then
        fail "$path: a .gitattributes changes how git checks out the evals"
      else
        case " $new_ids " in *" $id "*) ;; *) new_ids="${new_ids:+$new_ids }$id" ;; esac
      fi ;;
    *) fail "$path: a milestone changes only docs/prd.md, docs/research.md, VISION.md, and new" \
         "evals/<id>/ directories" ;;
  esac
done <"$tmp/diff"
[ "$prd" -eq 1 ] || fail "docs/prd.md: the milestone adds its ## Milestone $N section there"
[ "$vision" -eq 1 ] || fail "VISION.md: the milestone updates its ## Roadmap"
[ -n "$new_ids" ] || fail "no new eval: a milestone adds at least one evals/<id>/"
for id in $new_ids; do
  for f in scenario.md check.sh; do
    g cat-file -e "HEAD:evals/$id/$f" 2>/dev/null || fail "evals/$id/$f is missing"
  done
done

g log -1 --format=%B HEAD >"$tmp/message" || exit 3
grep -Eiq "$SKIP_RE" "$tmp/message" \
  && fail "the HEAD commit message holds a CI skip token: its workflows would not start"

ungrounded=0
if [ "$prd" -eq 1 ]; then
  g show "HEAD:docs/prd.md" >"$tmp/prd.head" || exit 3
  size="$(wc -c <"$tmp/prd.base" | tr -d ' ')"
  if ! head -c "$size" "$tmp/prd.head" | cmp -s - "$tmp/prd.base"; then
    fail "docs/prd.md: existing text changed: a milestone only appends its section"
  else
    tail -c +"$((size + 1))" "$tmp/prd.head" >"$tmp/added"
    # Prints FAIL lines, `ROW <id> <judge> <requirement>` per scenario, and `UNGROUNDED` / `URL`.
    out="$(awk -v n="$N" -v old="$(requirement_ids "$tmp/prd.base" | paste -sd ' ' -)" \
        -v evals="$new_ids" '
      function bad(m) { print "FAIL: docs/prd.md: ## Milestone " n ": " m }
      function done_req() { if (rq != "" && !crit) bad("requirement " rq " has no \047- \047 criteria") }
      function done_s() {
        if (sid == "") return
        if (sreq == "") bad("scenario " sid " needs a \047- requirement: R<k>\047 line")
        if (sjudge == "") bad("scenario " sid " needs a \047- judge: script\047 or \047- judge: model\047 line")
        if (!stext) bad("scenario " sid " has no scenario text")
        req_of[sid] = sreq; print "ROW", sid, sjudge, sreq }
      BEGIN { k = split(old, a, " "); for (i = 1; i <= k; i++) taken[a[i]] = 1
              k = split(evals, a, " "); for (i = 1; i <= k; i++) want[a[i]] = 1 }
      { line = $0; sub(/[ \t\r]+$/, "", line) }
      line ~ /https?:\/\// { print "URL" }
      line ~ /^## / { h2++
        if (h2 > 1) print "FAIL: docs/prd.md: append one ## Milestone " n " section, no other ## heading (\"" line "\")"
        else if (line !~ ("^## Milestone " n ": [^ \t]"))
          print "FAIL: docs/prd.md: the appended section must open with \047## Milestone " n ": <title>\047"
        next }
      !h2 { if (line ~ /[^ \t]/ && !pre++) print "FAIL: docs/prd.md: text appended before ## Milestone " n
            next }
      line == "ungrounded: no web access" && sec == "" { print "UNGROUNDED"; next }
      line ~ /^### / { done_req(); done_s(); sid = ""; rq = ""; h = substr(line, 5)
        if (h ~ /^R[0-9]+: [^ \t]/) {
          sec = "req"; rq = h; sub(/:.*/, "", rq); crit = 0
          if (rq in taken) bad("requirement " rq " is not new: number it after the PRD\047s")
          taken[rq] = 1; mine[rq] = 1; reqs++ }
        else if (h == "Success metrics") sec = "metrics"
        else if (h == "Scenarios") { sec = "scen"; scen_seen = 1 }
        else { sec = "other"; bad("\"### " h "\" is not ### R<k>: <title>, ### Success metrics, or ### Scenarios") }
        next }
      line ~ /^#### / {
        if (sec != "scen") { bad("\"" line "\" is outside ### Scenarios"); next }
        done_s(); sid = substr(line, 6); sreq = ""; sjudge = ""; stext = 0
        if (sid in seen) bad("scenario " sid " appears twice")
        seen[sid] = 1
        if (!(sid in want)) bad("scenario " sid " has no new evals/" sid "/")
        next }
      sec == "req" && line ~ /^- / { crit++ }
      sec == "metrics" && line ~ /^- / { metrics++ }
      sec == "scen" && sid != "" {
        if (line ~ /^- requirement:/) { v = line; sub(/^- requirement:[ \t]*/, "", v); sreq = v }
        else if (line ~ /^- judge:/) { v = line; sub(/^- judge:[ \t]*/, "", v)
          if (v == "script" || v == "model") { sjudge = v; if (v == "script") scripts++ }
          else bad("scenario " sid ": judge must be script or model (got \047" v "\047)") }
        else if (line ~ /[^ \t]/) stext = 1 }
      END { done_req(); done_s()
        if (!h2) { print "FAIL: docs/prd.md: append a \047## Milestone " n ": <title>\047 section"; exit }
        if (!reqs) bad("needs at least one ### R<k>: <title> requirement")
        if (!metrics) bad("needs ### Success metrics with at least one \047- \047 item")
        if (!scen_seen) bad("needs ### Scenarios, one #### <id> per new eval")
        else if (!scripts) bad("needs at least one scenario with \047- judge: script\047")
        for (id in req_of) if (req_of[id] != "" && !(req_of[id] in mine))
          bad("scenario " id " covers " req_of[id] ", which is not one of this section\047s requirements")
        for (id in want) if (!(id in seen)) bad("evals/" id "/ has no #### " id " scenario") }
      ' "$tmp/added")"
    printf '%s\n' "$out" | grep '^FAIL: ' && FAILS=$((FAILS + $(printf '%s\n' "$out" | grep -c '^FAIL: ')))
    grep -m 1 '^## ' "$tmp/added" | grep -Eiq "$SKIP_RE" \
      && fail "docs/prd.md: the ## Milestone $N title holds a CI skip token: the PR title carries" \
           "it into the merge commit, so the evals run on the default branch would not start"
    printf '%s\n' "$out" | grep -qx UNGROUNDED && ungrounded=1
    urls="$(printf '%s\n' "$out" | grep -cx URL)"
    # Each new eval's scenario.md front matter agrees with its scenario.
    while read -r _ id judge req; do
      case " $new_ids " in *" $id "*) ;; *) continue ;; esac
      g show "HEAD:evals/$id/scenario.md" 2>/dev/null >"$tmp/scenario" || continue
      awk -v id="$id" -v j="$judge" -v r="$req" '
        { sub(/[ \t\r]+$/, "") }
        NR == 1 { if ($0 != "---") exit; next }
        $0 == "---" { exit }
        $0 == "id: " id { a = 1 } $0 == "judge: " j { b = 1 } $0 == "requirement: " r { c = 1 }
        END { exit !(a && b && c) }' "$tmp/scenario" \
        || fail "evals/$id/scenario.md: its front matter needs id: $id, judge: $judge," \
             "and requirement: $req, as its #### $id scenario says"
    done <<EOF
$(printf '%s\n' "$out" | grep '^ROW ')
EOF
  fi
fi

if [ "$vision" -eq 1 ]; then
  # The VISION.md rules live in the guard auto runs on every PR; --milestone adds the Roadmap ones.
  vrc=0
  vout="$(bash "$HERE/octo-vision-guard.sh" --base "$mb" --head HEAD --milestone "$N" "$DIR")" \
    || vrc=$?
  case "$vrc" in
    0) ;;
    1) printf '%s\n' "$vout" | grep '^FAIL: ' || true
       FAILS=$((FAILS + $(printf '%s\n' "$vout" | grep -c '^FAIL: '))) ;;
    *) echo "octo-vision-guard.sh exited $vrc" >&2; exit 3 ;;
  esac
  [ "$ungrounded" -eq 0 ] \
    || { g diff --no-color --no-ext-diff --no-textconv --text "$mb" HEAD -- VISION.md | grep -E '^\+[^+]' | grep -Eq 'https?://' \
         && fail "VISION.md: an ungrounded milestone read no source, so it cites no URL"; }
fi

if [ "$ungrounded" -eq 1 ]; then
  [ "$research" -eq 0 ] \
    || fail "docs/research.md: an ungrounded milestone read no source, so it leaves the file as it is"
  [ "${urls:-0}" -eq 0 ] \
    || fail "docs/prd.md: an ungrounded milestone read no source, so its section cites no URL"
elif [ "$prd" -eq 1 ]; then
  [ "$research" -eq 1 ] \
    || fail "docs/research.md: a grounded milestone refreshes it with what it read (or mark the" \
         "section 'ungrounded: no web access')"
fi

rc=0
check="$(bash "$HERE/octo-genesis-check.sh" "$DIR")" || rc=$?
case "$rc" in
  0) ;;
  1) printf '%s\n' "$check" | grep '^FAIL: ' || true
     FAILS=$((FAILS + $(printf '%s\n' "$check" | grep -c '^FAIL: '))) ;;
  *) echo "octo-genesis-check.sh exited $rc" >&2; exit 3 ;;
esac

[ "$FAILS" -eq 0 ] || exit 1
echo "ok: milestone $N: $new_ids"
