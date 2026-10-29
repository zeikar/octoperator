#!/usr/bin/env bash
# octo-project-status.sh — ensure an issue/PR is on the Projects v2 board and set its Status by name.
#
# Usage:
#   octo-project-status.sh --owner PROJECT_OWNER --project NUMBER --url CONTENT_URL --status "In Progress"
#
# Resolves the project id, the "Status" single-select field, and the option matching --status
# (case-insensitive) automatically — no field/option IDs need to be configured. Adds the item to the
# board if it is not already present, then sets the Status. Uses only gh's built-in jq (no external
# jq dependency).
set -euo pipefail

POWNER="" PROJECT="" URL="" STATUS=""
# Under `set -e` a bare `shift 2` past the last argument would exit 1 with no message.
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --owner)   need_value "$@"; POWNER="$2"; shift 2 ;;
    --project) need_value "$@"; PROJECT="$2"; shift 2 ;;
    --url)     need_value "$@"; URL="$2"; shift 2 ;;
    --status)  need_value "$@"; STATUS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$POWNER" ] && [ -n "$PROJECT" ] && [ -n "$URL" ] && [ -n "$STATUS" ] || {
  echo "Usage: octo-project-status.sh --owner OWNER --project NUMBER --url CONTENT_URL --status NAME" >&2
  exit 2; }

PROJECT_ID=$(gh project view "$PROJECT" --owner "$POWNER" --format json --jq '.id') \
  || { echo "Cannot access project #$PROJECT (owner $POWNER). Try: gh auth refresh -s project" >&2; exit 1; }

# gh lists at most 30 fields by default; ask for more so a busy board's Status is not cut off.
FIELD_ID=$(gh project field-list "$PROJECT" --owner "$POWNER" --limit 100 --format json \
  --jq '.fields[] | select(.name=="Status") | .id')
[ -n "$FIELD_ID" ] || { echo "No single-select field named \"Status\" on project #$PROJECT." >&2; exit 1; }

# gh's built-in --jq has no --arg, so the status name reaches jq through the environment ($ENV)
# rather than being spliced into the program text.
# shellcheck disable=SC2016  # $ENV is a jq variable — must stay literal, not shell-expanded
OPTION_ID=$(WANT="$STATUS" gh project field-list "$PROJECT" --owner "$POWNER" --limit 100 \
  --format json --jq '.fields[] | select(.name=="Status") | .options[]
    | select((.name|ascii_downcase)==($ENV.WANT|ascii_downcase)) | .id')
if [ -z "$OPTION_ID" ]; then
  echo "Status \"$STATUS\" not found. Available options:" >&2
  gh project field-list "$PROJECT" --owner "$POWNER" --limit 100 --format json \
    --jq '.fields[] | select(.name=="Status") | .options[].name' | sed 's/^/  - /' >&2
  exit 1
fi

# item-add is idempotent: for content already on the board it returns the existing item, so no
# item-list scan is needed (that scan was capped at 2000 items and cost a full read per call).
ITEM_ID=$(gh project item-add "$PROJECT" --owner "$POWNER" --url "$URL" --format json --jq '.id') \
  || { echo "Failed to add $URL to project #$PROJECT." >&2; exit 1; }
[ -n "$ITEM_ID" ] || { echo "item-add returned no item id for $URL on project #$PROJECT." >&2; exit 1; }

gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" \
  --field-id "$FIELD_ID" --single-select-option-id "$OPTION_ID" >/dev/null
echo "Set Status=\"$STATUS\" for $URL on project #$PROJECT"
