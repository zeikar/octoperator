#!/usr/bin/env bash
# octo-evals-guard.sh — tell auto's merge gate whether a PR's evals guard passed on the reviewed
# commit, against the base branch's current tip.
#
# Usage:
#   octo-evals-guard.sh --repo OWNER/NAME --pr NUMBER --sha HEAD_SHA
#
# A base branch with no .github/workflows/evals-guard.yml (genesis writes it) needs no guard.
# Otherwise the newest `pull_request` run of that workflow on HEAD_SHA for this PR (by the run's
# `path` and `pull_requests`, so no other workflow's job of the same name counts) must hold the
# jobs `evals-guard append-only` and `evals-guard verdict`, both completed with success: a head
# commit whose message holds `[skip ci]` runs no workflow, so it has none, and GitHub's
# mergeStateStatus can read CLEAN all the same. A run whose PR is closed, or comes from a fork,
# lists no pull request, so it never counts.
#
# When the PR changes a path the guard reads (anything under evals/, or the root .gitattributes,
# a rename's old path included), each job must also have recorded, as its `evals-guard-base`
# notice, the base branch's tip: a guard run against an older base judged the new evals against
# code that is no longer there. A PR that changes neither has an empty diff for the guard on any
# base, so the base moving doesn't make it stale. The PR's file list is GitHub's for its current
# head; when it can't all be read (3000 files or more), the base is checked.
#
# Prints one line:
#   pass                                        both guard checks passed (against the tip, when
#                                               the PR changes evals/)
#   none                                        the base branch has no evals guard workflow
#   evals guard did not pass: <check> <state>   missing, pending, skipped, or failed
#   evals guard stale: <check> ran against <sha>, <branch> is at <sha>
# Read-only: `gh pr view` and `gh api` GETs.
#
# Exit codes: 0 pass or none, 1 hold (the line says why), 2 bad arguments, 3 a gh error.
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
  echo "Usage: octo-evals-guard.sh --repo OWNER/NAME --pr NUMBER --sha HEAD_SHA" >&2; exit 2; }
case "$PR" in *[!0-9]*) echo "--pr must be a number" >&2; exit 2 ;; esac
case "$SHA" in *[!0-9a-f]*) echo "--sha must be a full commit SHA" >&2; exit 2 ;; esac
[ "${#SHA}" -eq 40 ] || { echo "--sha must be a full commit SHA" >&2; exit 2; }

err="$(mktemp)" && [ -n "$err" ] || { echo "mktemp failed" >&2; exit 3; }
trap 'rm -f "$err"' EXIT
# gh_get <args...> : gh's output, or exit 3 with gh's error.
gh_get() { gh "$@" 2>"$err" || { cat "$err" >&2; exit 3; }; }

IFS=$'\t' read -r branch count <<EOF || exit 3
$(gh_get pr view "$PR" --repo "$REPO" --json baseRefName,changedFiles \
  --jq '[.baseRefName, .changedFiles] | @tsv')
EOF
[ -n "$branch" ] || { echo "gh printed no base branch for PR $PR" >&2; exit 3; }
tip="$(gh_get api "repos/$REPO/git/ref/heads/$branch" --jq .object.sha)" || exit 3
if ! gh api "repos/$REPO/contents/.github/workflows/evals-guard.yml?ref=$tip" --jq .type \
    >/dev/null 2>"$err"; then
  grep -q 'HTTP 404' "$err" && { echo none; exit 0; }
  cat "$err" >&2; exit 3
fi

# The newest guard run for this PR on the commit: a re-run keeps its id and the jobs endpoint
# gives its latest attempt; a reopened PR adds a run.
run="$(gh_get api --paginate \
  "repos/$REPO/actions/runs?head_sha=$SHA&event=pull_request&per_page=100" --jq \
  ".workflow_runs[] | select(.path == \".github/workflows/evals-guard.yml\"
     and any(.pull_requests[]?; .number == $PR)) | .id" | sort -n | tail -n 1)" || exit 3
jobs=""
if [ -n "$run" ]; then
  jobs="$(gh_get api --paginate "repos/$REPO/actions/runs/$run/jobs?filter=latest&per_page=100" \
    --jq '.jobs[] | [(.check_run_url | sub(".*/"; "")), .name, .status, (.conclusion // "none")]
      | @tsv')" || exit 3
fi

# One path per line, a rename's old path too; @tsv escapes a tab or newline inside a path.
files="$(gh_get api --paginate "repos/$REPO/pulls/$PR/files?per_page=100" \
  --jq '.[] | [.filename, (.previous_filename // "")] | @tsv')" || exit 3
listed="$(printf '%s\n' "$files" | grep -c . || true)"
touches=1
case "$count" in
  '' | *[!0-9]*) ;;
  *) if [ "$count" -lt 3000 ] && [ "$count" -eq "$listed" ] \
       && ! printf '%s\n' "$files" | tr '\t' '\n' | grep -Eq '^(evals(/|$)|\.gitattributes$)'; then
       touches=0
     fi ;;
esac

for check in "evals-guard append-only" "evals-guard verdict"; do
  row="$(printf '%s\n' "$jobs" | awk -F '\t' -v n="$check" '$2 == n { print; exit }')"
  if [ -z "$row" ]; then echo "evals guard did not pass: $check missing"; exit 1; fi
  IFS=$'\t' read -r id _ status conclusion <<EOF
$row
EOF
  if [ "$status" != completed ]; then echo "evals guard did not pass: $check $status"; exit 1; fi
  if [ "$conclusion" != success ]; then
    echo "evals guard did not pass: $check $conclusion"; exit 1
  fi
  [ "$touches" -eq 1 ] || continue
  case "$id" in '' | *[!0-9]*) echo "Unexpected check run URL for $check" >&2; exit 3 ;; esac
  ran="$(gh_get api --paginate "repos/$REPO/check-runs/$id/annotations?per_page=100" --jq \
    '.[] | select(.title == "evals-guard-base") | .message' | sort -u | paste -sd ' ' -)" \
    || exit 3
  if [ "$ran" != "$tip" ]; then
    echo "evals guard stale: $check ran against ${ran:-an unrecorded base}, $branch is at $tip"
    exit 1
  fi
done
echo pass
