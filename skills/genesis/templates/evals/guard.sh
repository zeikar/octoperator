#!/usr/bin/env bash
# guard.sh — fail a pull request that weakens the evals: evals only grow, and a new eval must fail
# on the default branch first.
#
# Usage:
#   bash guard.sh BASE HEAD
#
# Run it inside a clone that holds both commits: BASE, the PR's base (the default branch's tip),
# and HEAD, the PR's head. It looks at the PR's own changes under evals/, from the merge base of
# BASE and HEAD to HEAD (`git diff --name-status --no-renames`), and fails when:
#   - an existing file under evals/ is modified, deleted, or renamed (a rename is a delete);
#   - a file is added to an eval directory that already exists on BASE or the merge base;
#   - a new eval directory evals/<id>/ has no scenario.md, or its front matter lacks `id: <id>`
#     (lowercase kebab-case), `judge: script` or `judge: model`, or `requirement: R<n>`;
#   - a new `judge: script` eval has no check.sh, or a check.sh with a syntax error;
#   - a new `judge: script` eval's check.sh passes (exit 0) or times out on BASE's tree.
# A new `judge: model` eval is format-checked only: nothing here runs a model. A file added
# directly under evals/, outside any eval directory, is allowed.
#
# Each new check runs from HEAD's copy of its directory against a `git archive` of BASE, from a
# neutral `mktemp -d` directory with stdin from /dev/null, in its own process group, killed with
# every process it started after EVALS_CHECK_TIMEOUT seconds (default 120).
#
# The evals-guard workflow runs BASE's copy of this script, so a PR cannot change the guard it is
# judged by. Written by /octoperator:genesis.
#
# Exit codes: 0 the PR only adds must-fail evals (or leaves evals/ alone), 1 one `FAIL: <problem>`
# line per problem, 2 bad arguments, 3 git failed (git's output on stderr).
set -uo pipefail
export LC_ALL=C

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  -*) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
[ $# -eq 2 ] || { echo "Usage: bash guard.sh BASE HEAD" >&2; exit 2; }
TIMEOUT="${EVALS_CHECK_TIMEOUT:-120}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=0 ;; esac
[ "$TIMEOUT" -ge 1 ] || { echo "EVALS_CHECK_TIMEOUT must be a positive integer" >&2; exit 2; }

top="$(git rev-parse --show-toplevel)" || { echo "guard: not inside a git work tree" >&2; exit 3; }
g() { git -C "$top" "$@"; }
commit() {
  g rev-parse --verify --quiet "$1^{commit}" \
    || { echo "guard: no such commit: $1" >&2; exit 3; }
}
base="$(commit "$1")" || exit 3
head="$(commit "$2")" || exit 3
mb="$(g merge-base "$base" "$head")" \
  || { echo "guard: $1 and $2 have no merge base" >&2; exit 3; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "guard: mktemp failed" >&2; exit 3; }
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/cwd" "$tmp/head"

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

# fm_value <file> <key> : prints the key's value in the file's front matter, unquoted, or nothing.
fm_value() {
  awk -v k="$2" -v sq="'" 'NR == 1 { if ($0 != "---") exit; next }
       $0 == "---" { exit }
       index($0, k ":") == 1 { v = substr($0, length(k) + 2); gsub(/^[ \t]+|[ \t\r]+$/, "", v)
         gsub("^[\"" sq "]|[\"" sq "]$", "", v); print v; exit }' "$1"
}

# extract <commit> <dest> [path] : writes the commit's tree (or one path of it) into <dest>.
extract() {
  mkdir -p "$2" && g archive --format=tar "$1" ${3:+"$3"} | tar -xf - -C "$2" \
    || { echo "guard: git archive $1 ${3:-} failed" >&2; exit 3; }
}

# bounded <log> <command...> : run a command from a neutral directory, killed after $TIMEOUT
# seconds (exit 142). The command gets its own process group, so a timeout kills everything it
# started.
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
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$TIMEOUT" "$@") </dev/null >"$log" 2>&1
}

g diff --no-color --no-renames --no-ext-diff --name-status -z "$mb" "$head" -- evals \
  >"$tmp/diff" || { echo "guard: git diff failed" >&2; exit 3; }

new=""
while IFS= read -r -d '' st && IFS= read -r -d '' path; do
  case "$st" in
    A) ;;
    M) fail "$path: modifies an existing eval file"; continue ;;
    D) fail "$path: deletes (or renames) an existing eval file"; continue ;;
    *) fail "$path: changes an existing eval file (status $st)"; continue ;;
  esac
  rest="${path#evals/}"
  case "$rest" in */*) ;; *) continue ;; esac
  id="${rest%%/*}"
  if g cat-file -e "$base:evals/$id" 2>/dev/null || g cat-file -e "$mb:evals/$id" 2>/dev/null
  then
    fail "$path: adds a file to the existing eval evals/$id/"
    continue
  fi
  case $'\n'"$new" in *$'\n'"$id"$'\n'*) ;; *) new="$new$id"$'\n' ;; esac
done <"$tmp/diff"

n=0 based=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  n=$((n + 1))
  extract "$head" "$tmp/head" "evals/$id"
  d="$tmp/head/evals/$id"
  if [ ! -f "$d/scenario.md" ]; then fail "evals/$id/: a new eval needs scenario.md"; continue; fi
  v="$(fm_value "$d/scenario.md" id)"
  [ "$v" = "$id" ] && printf '%s\n' "$id" | grep -Eqx '[a-z0-9]+(-[a-z0-9]+)*' \
    || fail "evals/$id/scenario.md: front matter needs id: $id, in lowercase kebab-case" \
      "(got '$v')"
  v="$(fm_value "$d/scenario.md" requirement)"
  printf '%s\n' "$v" | grep -Eqx 'R[0-9]+' \
    || fail "evals/$id/scenario.md: front matter needs requirement: R<n> (got '$v')"
  j="$(fm_value "$d/scenario.md" judge)"
  case "$j" in
    model) echo "ok: evals/$id/ (judge: model: format checked, not run)"; continue ;;
    script) ;;
    *) fail "evals/$id/scenario.md: front matter needs judge: script or model (got '$j')"
       continue ;;
  esac
  if [ ! -f "$d/check.sh" ]; then fail "evals/$id/: a judge: script eval needs check.sh"; continue
  fi
  if ! bash -n "$d/check.sh" 2>"$tmp/$id.syntax"; then
    fail "evals/$id/check.sh: syntax error: $(head -n 1 "$tmp/$id.syntax")"
    continue
  fi
  [ "$based" -eq 1 ] || { extract "$base" "$tmp/base"; based=1; }
  bounded "$tmp/$id.log" bash "$d/check.sh" "$tmp/base"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "evals/$id/check.sh passes on the base ($1): a new eval must fail there first"
  elif [ "$rc" -eq 142 ]; then
    fail "evals/$id/check.sh timed out on the base (${TIMEOUT}s)"
  else
    echo "ok: evals/$id/ fails on the base (exit $rc)"
  fi
done <<EOF
$new
EOF

echo "evals-guard: $n new eval(s), $FAILS problem(s)"
[ "$FAILS" -eq 0 ]
