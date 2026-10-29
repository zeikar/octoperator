#!/usr/bin/env bash
# octo-exclude.sh — keep Octoperator's local files out of `git status` in the current repo.
#
# Octoperator writes .claude/octoperator.local.md (settings) and .octoperator/worktrees/
# (parallel worktrees) inside the target repo, whose own .gitignore knows nothing about them.
# Left alone they show as untracked, trip implement's clean-tree guard, and risk being
# committed. This idempotently adds both to the repo-local exclude file (.git/info/exclude),
# which is never committed — the tracked .gitignore is left untouched.
#
# Usage:
#   octo-exclude.sh
#
# Run from inside the target repo (any worktree). Exit code is non-zero on any error.
set -euo pipefail

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --git-path resolves to the shared (common-dir) exclude file even from a linked worktree.
EXCLUDE="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$EXCLUDE")"
touch "$EXCLUDE"
# A hand-edited file may lack a trailing newline; appending would glue onto its last pattern.
if [ -s "$EXCLUDE" ] && [ -n "$(tail -c 1 "$EXCLUDE")" ]; then echo >>"$EXCLUDE"; fi

for pattern in /.claude/octoperator.local.md /.octoperator/; do
  grep -Fqx -- "$pattern" "$EXCLUDE" || echo "$pattern" >>"$EXCLUDE"
done
