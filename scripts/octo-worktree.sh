#!/usr/bin/env bash
# octo-worktree.sh — manage Git worktrees for Octoperator feature branches.
#
# Usage:
#   octo-worktree.sh <action> [options]
#
# Actions:
#   add    --branch <b> --path <p> --base <ref>
#            Create a new worktree at <p> with a new branch <b> from <ref>.
#            Exits non-zero if <b> is already checked out in any worktree or
#            already exists as a local branch.
#   remove --path <p> [--force]
#            Remove the worktree at <p>.  Refuses if the tree is dirty or has
#            untracked files unless --force is given.
#   list
#            Print raw "git worktree list --porcelain" output for the caller.
#
# The caller (skill) is responsible for computing the branch name / slug.
# Exit code is non-zero on any error.
set -euo pipefail

ACTION="${1:-}"
case "$ACTION" in
  add|remove|list) shift ;;
  -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") echo "Usage: octo-worktree.sh <add|remove|list> [options]" >&2; exit 2 ;;
  *)  echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac

BRANCH="" WT_PATH="" BASE="" FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --path)   WT_PATH="${2:-}"; shift 2 ;;
    --base)   BASE="${2:-}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$ACTION" in

  add)
    [ -n "$BRANCH" ] || { echo "octo-worktree: --branch is required" >&2; exit 2; }
    [ -n "$WT_PATH" ] || { echo "octo-worktree: --path is required" >&2; exit 2; }
    [ -n "$BASE" ]   || { echo "octo-worktree: --base is required" >&2; exit 2; }

    # Check if the branch is already checked out in any existing worktree.
    if git worktree list --porcelain | grep -Fqx "branch refs/heads/${BRANCH}"; then
      echo "octo-worktree: branch '${BRANCH}' is already checked out in a worktree" >&2
      exit 1
    fi

    # Check if the local branch already exists.
    if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
      echo "octo-worktree: local branch '${BRANCH}' already exists" >&2
      exit 1
    fi

    git worktree add -b "${BRANCH}" "${WT_PATH}" "${BASE}"
    echo "${WT_PATH}"
    ;;

  remove)
    [ -n "$WT_PATH" ] || { echo "octo-worktree: --path is required" >&2; exit 2; }

    # Pre-flight dirty check to emit a clearer message than git worktree remove's own refusal.
    if [ "$FORCE" -eq 0 ]; then
      DIRTY=$(git -C "${WT_PATH}" status --porcelain)
      if [ -n "$DIRTY" ]; then
        echo "octo-worktree: worktree '${WT_PATH}' has uncommitted changes or untracked files; use --force to override" >&2
        exit 1
      fi
    fi

    if [ "$FORCE" -eq 1 ]; then
      git worktree remove --force "${WT_PATH}"
    else
      git worktree remove "${WT_PATH}"
    fi
    ;;

  list)
    git worktree list --porcelain
    ;;

esac
