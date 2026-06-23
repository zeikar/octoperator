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
while [ $# -gt 0 ]; do
  case "$1" in
    --owner)   POWNER="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --url)     URL="${2:-}"; shift 2 ;;
    --status)  STATUS="${2:-}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$POWNER" ] && [ -n "$PROJECT" ] && [ -n "$URL" ] && [ -n "$STATUS" ] || {
  echo "Usage: octo-project-status.sh --owner OWNER --project NUMBER --url CONTENT_URL --status NAME" >&2
  exit 2; }

PROJECT_ID=$(gh project view "$PROJECT" --owner "$POWNER" --format json --jq '.id') \
  || { echo "Cannot access project #$PROJECT (owner $POWNER). Try: gh auth refresh -s project" >&2; exit 1; }

FIELD_ID=$(gh project field-list "$PROJECT" --owner "$POWNER" --format json \
  --jq '.fields[] | select(.name=="Status") | .id')
[ -n "$FIELD_ID" ] || { echo "No single-select field named \"Status\" on project #$PROJECT." >&2; exit 1; }

WANT=$(printf '%s' "$STATUS" | tr '[:upper:]' '[:lower:]')
OPTION_ID=$(gh project field-list "$PROJECT" --owner "$POWNER" --format json \
  --jq ".fields[] | select(.name==\"Status\") | .options[] | select((.name|ascii_downcase)==\"$WANT\") | .id")
if [ -z "$OPTION_ID" ]; then
  echo "Status \"$STATUS\" not found. Available options:" >&2
  gh project field-list "$PROJECT" --owner "$POWNER" --format json \
    --jq '.fields[] | select(.name=="Status") | .options[].name' | sed 's/^/  - /' >&2
  exit 1
fi

# Reuse the existing board item for this URL if present; otherwise add it.
ITEM_ID=$(gh project item-list "$PROJECT" --owner "$POWNER" --format json --limit 2000 \
  --jq ".items[] | select(.content.url==\"$URL\") | .id" | head -1)
if [ -z "$ITEM_ID" ]; then
  ITEM_ID=$(gh project item-add "$PROJECT" --owner "$POWNER" --url "$URL" --format json --jq '.id') \
    || { echo "Failed to add $URL to project #$PROJECT." >&2; exit 1; }
fi

gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" \
  --field-id "$FIELD_ID" --single-select-option-id "$OPTION_ID" >/dev/null
echo "Set Status=\"$STATUS\" for $URL on project #$PROJECT"
