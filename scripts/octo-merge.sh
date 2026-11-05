#!/usr/bin/env bash
# octo-merge.sh — merge a PR with a regular merge commit, pinned to its reviewed head, then delete
# its branch, best effort.
#
# Usage:
#   octo-merge.sh --repo OWNER/NAME --pr NUMBER --sha HEAD_SHA
#
# REST only, the stand-in for `gh pr merge --merge --delete-branch --match-head-commit` (GraphQL,
# which a Claude Code cloud session refuses). Merges with `PUT .../pulls/N/merge`,
# `merge_method=merge` (never squash or rebase) and `sha=HEAD_SHA`, so GitHub refuses the merge
# (409) when the head has moved past the reviewed commit. GitHub's default merge commit title and
# message are kept ("Merge pull request #N from OWNER/branch"). Run it only after auto's gate
# passed.
#
# Then reads the PR back (`GET .../pulls/N`). The PR counts as merged when the merge call answered
# `merged: true` or the read-back says `.merged`: a merge can land even when the call reports an
# error, and a read-back can lag a merge that just landed. When the merge call failed and the
# read-back fails too, whether it merged is unknown. Once merged, deletes the head branch
# (`DELETE .../git/refs/heads/<branch>`) only when it is in OWNER/NAME (not a fork's, or a deleted
# fork's) and is not the default branch. A failed delete (a Claude Code cloud session's proxy
# refuses it with a 403) only warns.
#
# Prints, when merged (exit 0):
#   merged <merge commit sha>
#   warn: the merge call failed, but the PR merged: <gh's error>     (only then)
#   then one of: deleted branch <b> | branch <b> already deleted | kept branch <b>: <why> |
#   warn: branch <b> not deleted: <gh's error>
# When not merged (exit 1), one line:
#   not merged: head moved: <gh's error>        409: a push landed after the review
#   not merged: not mergeable: <gh's error>     405: conflicts, protection, or a draft
#   not merged: <gh's error>                    anything else (the PR read before merging too)
#
# Exit codes: 0 merged, 1 not merged, 2 bad arguments, 3 the merge call failed and the PR could not
# be read back, so whether it merged is unknown.
set -uo pipefail

REPO="" PR="" SHA=""
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --pr)   need_value "$@"; PR="$2"; shift 2 ;;
    --sha)  need_value "$@"; SHA="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$PR" ] && [ -n "$SHA" ] || {
  echo "Usage: octo-merge.sh --repo OWNER/NAME --pr NUMBER --sha HEAD_SHA" >&2; exit 2; }
case "$REPO" in
  */*/* | /* | */ | *[!A-Za-z0-9._/-]*) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
  */*) ;;
  *) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
esac
[[ "$PR" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "--pr must be a PR number" >&2; exit 2; }
case "$SHA" in *[!0-9a-f]*) echo "--sha must be a full commit SHA" >&2; exit 2 ;; esac
[ "${#SHA}" -eq 40 ] || { echo "--sha must be a full commit SHA" >&2; exit 2; }

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "mktemp failed" >&2; exit 3; }
trap 'rm -rf "$tmp"' EXIT
# gh_error : gh's one-line error from the last call, "gh: <message> (HTTP <code>)".
gh_error() { grep -m 1 . "$tmp/err" || echo "gh failed"; }

# The branch to delete, read before the merge: the head branch's name raw and path-encoded, its
# repo (`-` for a deleted fork: `read` would merge two tabs into one), and the default branch.
if ! gh api "repos/$REPO/pulls/$PR" --jq '[.head.ref, (.head.ref | split("/") | map(@uri) | join("/")),
      (.head.repo.full_name // "-"), .base.repo.default_branch] | @tsv' >"$tmp/pr" 2>"$tmp/err"; then
  echo "not merged: $(gh_error)"; exit 1
fi
IFS=$'\t' read -r branch branch_path head_repo default <"$tmp/pr"

merge_rc=0
gh api -X PUT "repos/$REPO/pulls/$PR/merge" -f merge_method=merge -f sha="$SHA" \
  --jq '[(.merged // false), (.sha // "")] | @tsv' >"$tmp/merge" 2>"$tmp/merge-err" || merge_rc=$?
put_merged="" put_sha="" merged="" merge_sha=""
[ "$merge_rc" -ne 0 ] || IFS=$'\t' read -r put_merged put_sha <"$tmp/merge"
if gh api "repos/$REPO/pulls/$PR" --jq '[.merged, (.merge_commit_sha // "")] | @tsv' \
    >"$tmp/after" 2>"$tmp/err"; then
  IFS=$'\t' read -r merged merge_sha <"$tmp/after"
elif [ "$merge_rc" -ne 0 ]; then
  cat "$tmp/merge-err" "$tmp/err" >&2
  echo "Merge call failed and PR #$PR could not be read back: whether it merged is unknown" >&2
  exit 3
fi
# The merge call's own merged:true stands even when the read-back lags behind it.
if [ "$merged" != true ] && [ "$put_merged" = true ]; then merged=true merge_sha="$put_sha"; fi

if [ "$merged" != true ]; then
  cp "$tmp/merge-err" "$tmp/err"
  if [ "$merge_rc" -eq 0 ]; then echo "not merged: GitHub answered the merge without merging"
  elif grep -q '(HTTP 409)' "$tmp/err"; then echo "not merged: head moved: $(gh_error)"
  elif grep -q '(HTTP 405)' "$tmp/err"; then echo "not merged: not mergeable: $(gh_error)"
  else echo "not merged: $(gh_error)"
  fi
  exit 1
fi
echo "merged $merge_sha"
if [ "$merge_rc" -ne 0 ]; then
  cp "$tmp/merge-err" "$tmp/err"
  echo "warn: the merge call failed, but the PR merged: $(gh_error)"
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
if [ "$head_repo" = - ]; then
  echo "kept branch $branch: its repo was deleted (a fork)"
elif [ "$(lower "$head_repo")" != "$(lower "$REPO")" ]; then
  echo "kept branch $branch: it is in another repo ($head_repo)"
elif [ "$branch" = "$default" ]; then
  echo "kept branch $branch: it is the default branch"
elif gh api -X DELETE "repos/$REPO/git/refs/heads/$branch_path" >/dev/null 2>"$tmp/err"; then
  echo "deleted branch $branch"
elif grep -q 'Reference does not exist' "$tmp/err"; then
  # The repo's "delete head branches" setting got there first.
  echo "branch $branch already deleted"
else
  echo "warn: branch $branch not deleted: $(gh_error)"
fi
exit 0
