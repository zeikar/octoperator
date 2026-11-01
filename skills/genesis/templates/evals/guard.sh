#!/usr/bin/env bash
# guard.sh — fail a pull request that weakens the evals: evals only grow, and a new eval must fail
# on the default branch first.
#
# Usage:
#   bash guard.sh [--diff-only] BASE HEAD
#   bash guard.sh --run-new BASE HEAD RESULTS
#   bash guard.sh --verdict BASE HEAD RESULTS
#
# Run it inside a clone that holds both commits: BASE, the PR's base (the default branch's tip),
# and HEAD, the PR's head. It reads the PR's own changes, from the merge base of BASE and HEAD to
# HEAD (`git diff --raw --no-renames`), under evals/ and to the root .gitattributes.
#
# The append-only rule (--diff-only checks only this; it reads git objects and runs nothing from
# the PR). It fails when:
#   - an existing file under evals/ is modified (its mode too), deleted, renamed (a rename is a
#     delete), or changes type;
#   - the root .gitattributes changes, or a .gitattributes is added under evals/: either changes
#     how git checks the evals out;
#   - a symlink or a submodule is added under evals/, or a file directly under evals/;
#   - a path under evals/ holds a control character;
#   - a file is added to an eval directory that already exists on BASE or the merge base;
#   - a new eval directory evals/<id>/ has no scenario.md, or its front matter lacks `id: <id>`
#     (lowercase kebab-case), `judge: script` or `judge: model`, or `requirement: R<n>`;
#   - a new `judge: script` eval has no check.sh, or a check.sh with a syntax error.
#
# Must-fail-first. --run-new runs each new `judge: script` eval's check.sh and writes one
# `<id> <exit code>` line per check to RESULTS, or `<id> modified` when the check changed the tree
# it judged. --verdict reads RESULTS and fails each new script eval with no line there, or whose
# check passed (exit 0), timed out (142), or changed the tree. With no flag, the guard does all
# three in one process. A new `judge: model` eval is format-checked only: nothing here runs a
# model.
#
# Each check gets a fresh tree: a `git clone --shared` of BASE with every new eval directory from
# HEAD laid over it, committed on top of BASE (so it has a .git and a clean status), and the
# workspace's ignored directories (node_modules/, …) linked in. It runs as evals/run.sh runs it,
# `bash <tree>/evals/<id>/check.sh <tree>`: from a neutral `mktemp -d` directory, under
# `env -i PATH=… HOME=…`, stdin from /dev/null, in its own process group, killed with every
# process it started when it exits or after EVALS_CHECK_TIMEOUT seconds (default 120).
#
# The evals-guard workflow runs BASE's copy of this script (`bash -c "$(git show …)"`), so a PR
# cannot change the guard it is judged by: --diff-only in a job that runs no PR code, --run-new
# after the stack's setup, and --verdict in a third job, again with no PR code. Written by
# /octoperator:genesis.
#
# Exit codes: 0 no problem (--run-new: every check ran), 1 one `FAIL: <problem>` line per
# problem, 2 bad arguments, 3 git failed (git's output on stderr).
set -uo pipefail
# No replace refs: a `git replace` planted before the guard runs must not swap BASE or HEAD.
export LC_ALL=C GIT_NO_REPLACE_OBJECTS=1 GIT_LITERAL_PATHSPECS=1

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

g() { git -C "$top" "$@"; }
commit() {
  g rev-parse --verify --quiet "$1^{commit}" \
    || { echo "guard: no such commit: $1" >&2; exit 3; }
}

# fm_value <file> <key> : prints the key's value in the file's front matter, unquoted, or nothing.
fm_value() {
  awk -v k="$2" -v sq="'" 'NR == 1 { if ($0 != "---") exit; next }
       $0 == "---" { exit }
       index($0, k ":") == 1 { v = substr($0, length(k) + 2); gsub(/^[ \t]+|[ \t\r]+$/, "", v)
         gsub("^[\"" sq "]|[\"" sq "]$", "", v); print v; exit }' "$1"
}

# head_file <path> <dest> : writes HEAD's regular file at <path> to <dest>; fails when HEAD has
# none there.
head_file() {
  [ "$(g cat-file -t "$head:$1" 2>/dev/null)" = blob ] && g cat-file blob "$head:$1" >"$2"
}

# scan : reads the PR's diff; fails each change the append-only rule forbids, and sets `new` to
# the new eval ids, one per line.
scan() {
  local meta path st dmode rest id
  g diff --no-color --no-renames --no-ext-diff --no-textconv --raw -z "$mb" "$head" \
    -- evals .gitattributes >"$tmp/diff" || { echo "guard: git diff failed" >&2; exit 3; }
  new=""
  # Each entry: ":<old mode> <new mode> <old sha> <new sha> <status>" NUL "<path>" NUL.
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    st="${meta##* }" dmode="${meta#* }" dmode="${dmode%% *}"
    # A newline in a path could print a workflow command on a line of its own.
    case "$path" in
      *[[:cntrl:]]*)
        fail "a path under evals/ holds a control character (a newline, …)"; continue ;;
    esac
    if [ "$path" = .gitattributes ]; then
      fail ".gitattributes: changes how git checks out the evals (status $st)"
      continue
    fi
    case "$st" in
      A) ;;
      M) fail "$path: modifies an existing eval file"; continue ;;
      D) fail "$path: deletes (or renames) an existing eval file"; continue ;;
      *) fail "$path: changes an existing eval file (status $st)"; continue ;;
    esac
    case "$dmode" in
      120000) fail "$path: adds a symlink: evals hold regular files only"; continue ;;
      160000) fail "$path: adds a submodule: evals hold regular files only"; continue ;;
    esac
    rest="${path#evals/}"
    case "$rest" in
      */*) ;;
      *) fail "$path: adds a file directly under evals/, outside an eval directory"; continue ;;
    esac
    case "/$rest" in
      */.gitattributes)
        fail "$path: adds a .gitattributes, which changes how git checks out the eval"
        continue ;;
    esac
    id="${rest%%/*}"
    if g cat-file -e "$base:evals/$id" 2>/dev/null || g cat-file -e "$mb:evals/$id" 2>/dev/null
    then
      fail "$path: adds a file to the existing eval evals/$id/"
      continue
    fi
    case $'\n'"$new" in *$'\n'"$id"$'\n'*) ;; *) new="$new$id"$'\n' ;; esac
  done <"$tmp/diff"
}

# formats : checks each new eval's files, read from HEAD's objects; counts them in `n`, and sets
# `scripts` to the well-formed `judge: script` ids, one per line.
formats() {
  local id v j s="$tmp/scenario.md" c="$tmp/check.sh" okid
  n=0 scripts=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    if ! head_file "evals/$id/scenario.md" "$s"; then
      fail "evals/$id/: a new eval needs scenario.md"
      continue
    fi
    okid=1
    v="$(fm_value "$s" id)"
    if [ "$v" != "$id" ] || ! printf '%s\n' "$id" | grep -Eqx '[a-z0-9]+(-[a-z0-9]+)*'; then
      okid=0
      fail "evals/$id/scenario.md: front matter needs id: $id, in lowercase kebab-case (got '$v')"
    fi
    v="$(fm_value "$s" requirement)"
    printf '%s\n' "$v" | grep -Eqx 'R[0-9]+' \
      || fail "evals/$id/scenario.md: front matter needs requirement: R<n> (got '$v')"
    j="$(fm_value "$s" judge)"
    case "$j" in
      model) echo "ok: evals/$id/ (judge: model: format checked, not run)"; continue ;;
      script) ;;
      *) fail "evals/$id/scenario.md: front matter needs judge: script or model (got '$j')"
         continue ;;
    esac
    if ! head_file "evals/$id/check.sh" "$c"; then
      fail "evals/$id/: a judge: script eval needs check.sh"
      continue
    fi
    if ! bash -n "$c" 2>"$tmp/syntax"; then
      fail "evals/$id/check.sh: syntax error: $(head -n 1 "$tmp/syntax")"
      continue
    fi
    # Only a kebab-case id goes into RESULTS, whose lines are `<id> <exit code>`.
    [ "$okid" -eq 0 ] || scripts="$scripts$id"$'\n'
  done <<EOF
$new
EOF
}

# bounded <log> <command...> : run a command from a neutral directory, with only PATH and HOME
# in its environment, killed after $TIMEOUT seconds (exit 142). The command gets its own process
# group, killed too once the command exits, so nothing it left running outlives it.
bounded() {
  local log="$1"; shift
  (cd "$tmp/cwd" && perl -e '
    $t = shift;
    defined($pid = fork) or die "fork: $!\n";
    if (!$pid) { setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!\n"; }
    setpgrp($pid, $pid);
    $SIG{ALRM} = sub { kill "KILL", -$pid; exit 142 };
    $SIG{$_} = sub { kill "KILL", -$pid; $SIG{$_[0]} = "DEFAULT"; kill $_[0], $$ }
      for qw(INT TERM HUP);
    alarm $t;
    waitpid($pid, 0);
    $rc = $?;
    alarm 0;
    kill "KILL", -$pid;
    exit($rc & 127 ? 128 + ($rc & 127) : $rc >> 8);
  ' "$TIMEOUT" env -i PATH="$PATH" HOME="${HOME-}" "$@") </dev/null >"$log" 2>&1
}

# snap <tree> : prints what a check must leave alone: HEAD, and the status, ignored files too.
snap() {
  git -C "$1" rev-parse --verify HEAD && git -C "$1" --no-optional-locks status --porcelain \
    --ignored -uall
}

# fresh_tree <dest> : a fresh tree at <dest>: BASE with every new eval directory from HEAD,
# committed on top of BASE and checked out, plus a link to each of the workspace's ignored
# directories.
fresh_tree() {
  local wt="$1" id t c p
  {
    git -c core.hooksPath=/dev/null clone -q --shared --no-checkout "$top" "$wt" \
      && git -C "$wt" read-tree "$base"
  } || { echo "guard: could not clone $top" >&2; exit 3; }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    g ls-tree -r -z "$head" -- "evals/$id" | git -C "$wt" update-index -z --index-info \
      || { echo "guard: could not lay evals/$id/ over the base" >&2; exit 3; }
  done <<EOF
$new
EOF
  t="$(git -C "$wt" write-tree)" \
    && c="$(git -C "$wt" -c user.name=evals-guard -c user.email=evals-guard@localhost \
      -c commit.gpgsign=false commit-tree "$t" -p "$base" -m "the base with the new evals")" \
    && git -C "$wt" -c core.hooksPath=/dev/null checkout -q -f --detach "$c" \
    || { echo "guard: could not check out the base with the new evals" >&2; exit 3; }
  # The stack's setup installed the dependencies into the workspace (ignored, so not in BASE).
  mkdir -p "$wt/.git/info"
  while IFS= read -r -d '' p; do
    case "$p" in */) p="${p%/}" ;; *) continue ;; esac
    case "$p" in evals | evals/* | .git | */.git | *[[:cntrl:]]*) continue ;; esac
    if [ ! -e "$wt/$p" ] && [ ! -L "$wt/$p" ] && [ -d "$wt/$(dirname "$p")" ]; then
      ln -s "$top/$p" "$wt/$p" && printf '/%s\n' "$p" >>"$wt/.git/info/exclude"
    fi
  done <"$tmp/ignored"
}

# run_new <results> : runs each new script eval's check on its own fresh tree; one line each.
run_new() {
  local id k=0 rc wt
  printf '# evals-guard must-fail results: <id> <exit code>\n' >"$1" \
    || { echo "guard: cannot write $1" >&2; exit 3; }
  g ls-files -z --others --ignored --exclude-standard --directory >"$tmp/ignored" \
    || { echo "guard: git ls-files failed" >&2; exit 3; }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    k=$((k + 1))
    wt="$tmp/t$k/$(basename "$top")"
    fresh_tree "$wt"
    snap "$wt" >"$tmp/before" 2>/dev/null || { echo "guard: git status failed in $wt" >&2; exit 3; }
    bounded "$tmp/t$k.log" bash "$wt/evals/$id/check.sh" "$wt"
    rc=$?
    if ! { snap "$wt" >"$tmp/after" 2>/dev/null && cmp -s "$tmp/before" "$tmp/after"; }; then
      rc=modified
    fi
    printf '%s %s\n' "$id" "$rc" >>"$1"
    echo "ran: evals/$id/check.sh on the base: $rc"
    rm -rf "$tmp/t$k"
  done <<EOF
$scripts
EOF
  ran=$k
}

# verdict <results> : fails each new script eval whose check did not fail cleanly on the base.
verdict() {
  local id r
  judged=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    judged=$((judged + 1))
    r="$(awk -v id="$id" '$1 == id { print $2; exit }' "$1" 2>/dev/null)"
    case "$r" in
      '') fail "evals/$id/check.sh: no must-fail result: it did not run on the base" ;;
      0) fail "evals/$id/check.sh passes on the base ($base_arg): a new eval must fail" \
        "there first" ;;
      142) fail "evals/$id/check.sh timed out on the base (${TIMEOUT}s)" ;;
      modified) fail "evals/$id/check.sh changes the repo it judges: a check must leave" \
        "<repo-dir> as it found it" ;;
      *[!0-9]*) fail "evals/$id/check.sh: an unreadable must-fail result" ;;
      *) echo "ok: evals/$id/ fails on the base (exit $r)" ;;
    esac
  done <<EOF
$scripts
EOF
}

main() {
  local mode=all want=2
  case "${1:-}" in
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; return 0 ;;
    --diff-only) mode=append; shift ;;
    --run-new) mode=run want=3; shift ;;
    --verdict) mode=verdict want=3; shift ;;
    -*) echo "Unknown argument: $1" >&2; return 2 ;;
  esac
  [ $# -eq "$want" ] || {
    echo "Usage: bash guard.sh [--diff-only] BASE HEAD | --run-new|--verdict BASE HEAD RESULTS" >&2
    return 2; }
  TIMEOUT="${EVALS_CHECK_TIMEOUT:-120}"
  case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=0 ;; esac
  [ "$TIMEOUT" -ge 1 ] || { echo "EVALS_CHECK_TIMEOUT must be a positive integer" >&2; return 2; }

  top="$(git rev-parse --show-toplevel)" \
    || { echo "guard: not inside a git work tree" >&2; return 3; }
  base_arg="$1"
  base="$(commit "$1")" || return 3
  head="$(commit "$2")" || return 3
  mb="$(g merge-base "$base" "$head")" \
    || { echo "guard: $1 and $2 have no merge base" >&2; return 3; }
  tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "guard: mktemp failed" >&2; return 3; }
  trap 'rm -rf "$tmp"' EXIT
  mkdir "$tmp/cwd"

  case "$mode" in
    append)
      scan; formats
      echo "evals-guard: $n new eval(s), $FAILS problem(s)" ;;
    run)
      # The append-only job reports these problems; here they only pick the checks to run.
      { scan; formats; } >/dev/null; FAILS=0
      run_new "$3"
      echo "evals-guard: ran $ran new check(s) on the base; the verdict job judges them"
      return 0 ;;
    verdict)
      { scan; formats; } >/dev/null; FAILS=0
      verdict "$3"
      echo "evals-guard: $judged new script eval(s) judged, $FAILS problem(s)" ;;
    all)
      scan; formats
      run_new "$tmp/results" >/dev/null
      verdict "$tmp/results"
      echo "evals-guard: $n new eval(s), $FAILS problem(s)" ;;
  esac
  [ "$FAILS" -eq 0 ]
}

# The whole script is parsed before main runs, and this line ends it: a check that rewrites this
# file while it runs cannot change what runs after it.
main "$@"; exit $?
