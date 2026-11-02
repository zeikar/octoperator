#!/usr/bin/env bash
# octo-web-allowed.sh — whether your own Claude Code permission settings let autopilot's
# `genesis --next` call WebSearch and WebFetch without a prompt
# (skills/autopilot/references/milestone.md → Web access).
#
# Usage:
#   octo-web-allowed.sh DIR
#
# DIR is the repo's root. Reads DIR/.claude/settings.json, DIR/.claude/settings.local.json, and
# $HOME/.claude/settings.json; a missing file adds nothing. Both tools are allowed only when, for
# each of them:
#   - a file's `permissions.allow` holds the bare entry (`"WebSearch"`, `"WebFetch"`), and
#   - no file's `permissions.deny` or `permissions.ask` names it, bare or scoped
#     (`"WebFetch(domain:example.com)"`): a deny or ask rule wins over an allow.
# A file that is not valid JSON, or whose `permissions` or its `allow`, `deny`, or `ask` has the
# wrong type, allows nothing. The CLI's --allowedTools and managed settings are not read: an
# allow there goes unseen, so the run plans ungrounded more often, never the other way.
#
# Prints one line:
#   web: allowed
#   web: not allowed (<the first reason>)
#
# Offline and read-only.
#
# Exit codes: 0 decided, 2 bad arguments or DIR is not a directory.
set -uo pipefail

DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$DIR" ] || { echo "One DIR only" >&2; exit 2; }; DIR="$1"; shift ;;
  esac
done
[ -n "$DIR" ] || { echo "Usage: octo-web-allowed.sh DIR" >&2; exit 2; }
[ -d "$DIR" ] || { echo "Not a directory: $DIR" >&2; exit 2; }
command -v jq >/dev/null || { echo "web: not allowed (jq is not installed)"; exit 0; }

no() { echo "web: not allowed ($1)"; exit 0; }
# Each file's lines: `allow <tool>` for a bare allow entry, `deny <tool> <file>` or
# `ask <tool> <file>` for a rule naming the tool at all.
rules=""
# <how a reason names the file> <its path>, one pair per line.
while read -r name f; do
  [ -n "$f" ] && [ -e "$f" ] || continue
  jq -e 'type == "object" and ((.permissions // {}) | type == "object"
      and all(.allow, .deny, .ask; . == null or type == "array"))' "$f" >/dev/null 2>&1 \
    || no "$name is not valid settings JSON"
  out="$(jq -r --arg n "$name" '(.permissions // {}) as $p
    | ($p.allow // [] | .[] | strings | select(. == "WebSearch" or . == "WebFetch")
        | "allow \(.)"),
      (("deny", "ask") as $k | $p[$k] // [] | .[] | strings as $e
        | ("WebSearch", "WebFetch") as $t | select($e == $t or ($e | startswith($t + "(")))
        | "\($k) \($t) \($n)")' "$f")" || no "$name is unreadable"
  rules="$rules$out"$'\n'
done <<EOF
.claude/settings.json $DIR/.claude/settings.json
.claude/settings.local.json $DIR/.claude/settings.local.json
~/.claude/settings.json ${HOME:+$HOME/.claude/settings.json}
EOF

for t in WebSearch WebFetch; do
  hit="$(printf '%s' "$rules" | grep -E -m 1 "^(deny|ask) $t ")" \
    && no "${hit#* * }'s permissions.${hit%% *} names $t"
done
for t in WebSearch WebFetch; do
  printf '%s' "$rules" | grep -qx "allow $t" || no "no bare \"$t\" in permissions.allow"
done
echo "web: allowed"
