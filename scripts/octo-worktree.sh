#!/usr/bin/env bash
# octo-worktree.sh — manage Git worktrees for Octoperator feature branches.
#
# Usage:
#   octo-worktree.sh <action> [options]
#
# Actions:
#   add    --branch <b> --path <p> --base <ref>
#            Create a new worktree at <p> with a new branch <b> from <ref>, and
#            print <p> (only) on stdout; git's own progress goes to stderr.
#            Exits non-zero if <b> is already checked out in any worktree or
#            already exists as a local branch.
#   attach --branch <b> --path <p>
#            Resume on <b>, a branch that already exists on origin: fetch it into
#            origin/<b>, then create a worktree at <p> on a local <b> tracking it,
#            and print <p> (only) on stdout. A local <b> left by an earlier run is
#            reused when it matches origin/<b> or is ahead of it; when it is behind
#            or has diverged, exits 1 and leaves it alone (no commit is discarded).
#            Exits 1 if <b> is already checked out in any worktree or is absent on
#            origin.
#   detach --name <prefix> --ref <commit>
#            Create a throwaway detached worktree of <commit> (already in the local
#            object store) at <repo-root>/.octoperator/worktrees/<prefix>-<pid>, and
#            print that path (only) on stdout. The pid suffix keeps concurrent runs
#            from sharing a tree. Works even when <commit>'s branch is checked out.
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
  add|attach|detach|remove|list) shift ;;
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: octo-worktree.sh <add|attach|detach|remove|list> [options]" >&2; exit 2 ;;
  *)  echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac

BRANCH="" WT_PATH="" BASE="" NAME="" REF="" FORCE=0
# Under `set -e` a bare `shift 2` past the last argument would exit 1 with no message.
need_value() { [ $# -ge 2 ] || { echo "octo-worktree: missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) need_value "$@"; BRANCH="$2"; shift 2 ;;
    --path)   need_value "$@"; WT_PATH="$2"; shift 2 ;;
    --base)   need_value "$@"; BASE="$2"; shift 2 ;;
    --name)   need_value "$@"; NAME="$2"; shift 2 ;;
    --ref)    need_value "$@"; REF="$2"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$ACTION" in

  add)
    [ -n "$BRANCH" ] || { echo "octo-worktree: --branch is required" >&2; exit 2; }
    [ -n "$WT_PATH" ] || { echo "octo-worktree: --path is required" >&2; exit 2; }
    [ -n "$BASE" ]   || { echo "octo-worktree: --base is required" >&2; exit 2; }

    # Check if the branch is already checked out in any existing worktree. grep -c, not -q: it
    # reads to the end, so git can't die of SIGPIPE, which pipefail would read as no match (#133).
    if git worktree list --porcelain | grep -Fxc "branch refs/heads/${BRANCH}" >/dev/null; then
      echo "octo-worktree: branch '${BRANCH}' is already checked out in a worktree" >&2
      exit 1
    fi

    # Check if the local branch already exists.
    if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
      echo "octo-worktree: local branch '${BRANCH}' already exists" >&2
      exit 1
    fi

    # git prints "HEAD is now at …" on stdout; send it to stderr so stdout is only the path.
    git worktree add -b "${BRANCH}" "${WT_PATH}" "${BASE}" >&2
    echo "${WT_PATH}"
    ;;

  attach)
    [ -n "$BRANCH" ] || { echo "octo-worktree: --branch is required" >&2; exit 2; }
    [ -n "$WT_PATH" ] || { echo "octo-worktree: --path is required" >&2; exit 2; }

    if git worktree list --porcelain | grep -Fxc "branch refs/heads/${BRANCH}" >/dev/null; then
      echo "octo-worktree: branch '${BRANCH}' is already checked out in a worktree" >&2
      exit 1
    fi

    # An explicit refspec, so a single-branch clone still gets origin/<b>.
    if ! git fetch --no-tags origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" >&2; then
      echo "octo-worktree: could not fetch '${BRANCH}' from origin (absent, or the fetch failed)" >&2
      exit 1
    fi

    if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
      # A crashed run's local branch: reuse it only when it holds every remote commit.
      if ! git merge-base --is-ancestor "refs/remotes/origin/${BRANCH}" "refs/heads/${BRANCH}"; then
        echo "octo-worktree: local branch '${BRANCH}' is behind or has diverged from origin/${BRANCH}; resolve it by hand" >&2
        exit 1
      fi
      # Track first, so a failure here leaves no worktree behind.
      if ! git branch --set-upstream-to="origin/${BRANCH}" "${BRANCH}" >&2; then
        echo "octo-worktree: could not set '${BRANCH}' to track origin/${BRANCH}" >&2
        exit 1
      fi
      git worktree add "${WT_PATH}" "${BRANCH}" >&2
    else
      git worktree add --track -b "${BRANCH}" "${WT_PATH}" "origin/${BRANCH}" >&2
    fi
    echo "${WT_PATH}"
    ;;

  detach)
    [ -n "$NAME" ] || { echo "octo-worktree: --name is required" >&2; exit 2; }
    [ -n "$REF" ]  || { echo "octo-worktree: --ref is required" >&2; exit 2; }

    WT_PATH="$(git rev-parse --show-toplevel)/.octoperator/worktrees/${NAME}-$$"
    git worktree add --detach "${WT_PATH}" "${REF}" >&2
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
