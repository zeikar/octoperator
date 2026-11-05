#!/usr/bin/env bash
# octo-labels.sh — make sure labels exist in a repo: create each one that is missing, and leave
# every existing label exactly as it is.
#
# Usage:
#   octo-labels.sh --repo OWNER/NAME <label>...
#
# REST only (`POST repos/OWNER/NAME/labels`): `gh label create` uses GraphQL, which a Claude Code
# cloud session's proxy refuses. A label Octoperator defines (the type, priority, and workflow
# labels in skills/github-conventions/references/conventions.md) is created with its color and
# description from the table below; any other name gets color ededed and no description. GitHub
# answers 422 `already_exists` for a label that is there, whatever its case, and that label is
# not changed.
#
# Prints one line per label: `created <label>`, `exists <label>`, or
# `failed <label>: <gh's error>`.
# Exit codes: 0 every label exists now, 1 a create failed (the rest were still tried),
# 2 bad arguments.
set -uo pipefail

REPO=""
LABELS=()
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) LABELS+=("$1"); shift ;;
  esac
done

USAGE="Usage: octo-labels.sh --repo OWNER/NAME <label>..."
[ -n "$REPO" ] && [ "${#LABELS[@]}" -ge 1 ] || { echo "$USAGE" >&2; exit 2; }
case "$REPO" in
  */*/* | /* | */ | *[!A-Za-z0-9._/-]*) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
  */*) ;;
  *) echo "--repo must be OWNER/NAME" >&2; exit 2 ;;
esac
for l in "${LABELS[@]}"; do
  case "$l" in
    "" | *[[:cntrl:]]*) echo "a label name must be non-empty, on one line" >&2; exit 2 ;;
  esac
done

# spec <name> : "<color>|<description>" for a label Octoperator defines (conventions.md).
spec() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    epic)               echo "6f42c1|Large body of work" ;;
    feature)            echo "0e8a16|New capability" ;;
    bug)                echo "d73a4a|Defect" ;;
    chore)              echo "fbca04|Maintenance" ;;
    docs)               echo "0075ca|Documentation" ;;
    p0 | p1 | p2 | p3)  echo "ededed|" ;;
    ready)              echo "0E8A16|Blessed for automated build (autopilot)" ;;
    proposed)           echo "BFD4F2|Research-proposed; awaiting human triage" ;;
    octoperator-ledger) echo "5319E7|Autopilot run ledger: one entry per run" ;;
    needs-approval)     echo "D93F0B|Deploys, spends, or deletes: needs a human to add approved" ;;
    approved)           echo "0E8A16|Human-approved to build a needs-approval issue (never set by Octoperator)" ;;
    *)                  echo "ededed|" ;;
  esac
}

ERRF=$(mktemp) || { echo "octo-labels: mktemp failed" >&2; exit 1; }
trap 'rm -f "$ERRF"' EXIT

failed=0
for l in "${LABELS[@]}"; do
  s=$(spec "$l")
  # -f, never -F: a name or description is a string, even one starting with @ or a digit.
  out=$(gh api "repos/$REPO/labels" -f name="$l" -f color="${s%%|*}" -f description="${s#*|}" \
    2>"$ERRF")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "created $l"
  # On an HTTP error gh prints the response body on stdout: a 422 lists the field's error code.
  elif [[ "$out" == *'"already_exists"'* ]]; then
    echo "exists $l"
  else
    err=$(tail -n 1 "$ERRF")
    echo "failed $l: ${err:-gh exited $rc with no error output}"
    failed=1
  fi
done
exit "$failed"
