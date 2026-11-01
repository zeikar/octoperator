#!/usr/bin/env bash
# octo-approval-match.sh — match a PR's changed files against `approval_paths` patterns.
#
# Usage:
#   octo-approval-match.sh --pattern GLOB [--pattern GLOB ...] --repo OWNER/NAME --pr NUMBER
#   octo-approval-match.sh --pattern GLOB [--pattern GLOB ...] --normalize
#
# Normalizes each pattern: a leading `/` or `./` is dropped (the pattern stays anchored at the
# repo root), a trailing `/` becomes `/**`, and any other pattern with no `/` matches at any
# depth (`*.tf` → `**/*.tf`). Every pattern also covers all paths under a directory it matches
# (`infra` → also `infra/**`). `*` matches within one path segment and `**` matches zero or more
# whole segments; matching is case-sensitive and anchored at the repo root. `?` `[` `]` `{` `}` `!`, a backslash, an empty pattern or segment, a `.` or
# `..` segment, and a `**` that is not a whole segment are malformed.
#
# --normalize prints each normalized pattern, one per line, and makes no gh call. Otherwise lists
# every path the PR touches (a renamed file's old path too) and prints each match as
# `<path><TAB><pattern>`, one per line.
#
# Exit codes: 0 no match (or --normalize succeeded), 1 a match was found and printed, 2 bad
# arguments or a malformed pattern, 3 the PR's changed files could not all be read (a gh error,
# 3000 or more files, the API's limit, or a path with a tab or newline in it).
set -euo pipefail

REPO="" PR="" NORMALIZE=0
PATTERNS=()
# Under `set -e` a bare `shift 2` past the last argument would exit 1 with no message.
need_value() { [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --pattern)   need_value "$@"; PATTERNS+=("$2"); shift 2 ;;
    --repo)      need_value "$@"; REPO="$2"; shift 2 ;;
    --pr)        need_value "$@"; PR="$2"; shift 2 ;;
    --normalize) NORMALIZE=1; shift ;;
    -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

usage="Usage: octo-approval-match.sh --pattern GLOB [...] (--repo R --pr N | --normalize)"
[ "${#PATTERNS[@]}" -gt 0 ] || { echo "$usage" >&2; exit 2; }
if [ "$NORMALIZE" -eq 0 ]; then
  [ -n "$REPO" ] && [ -n "$PR" ] || { echo "$usage" >&2; exit 2; }
  case "$PR" in *[!0-9]*) echo "--pr must be a number" >&2; exit 2 ;; esac
fi

# normalize <pattern> : prints the normalized pattern, or exits 2 when it is malformed.
normalize() {
  local p="$1" out="" seg anchored=0
  case "$p" in
    ./*) p="${p#./}"; anchored=1 ;;
    /*)  p="${p#/}"; anchored=1 ;;
  esac
  case "$p" in */) p="${p}**" ;; esac
  case "$p" in
    '' | *[][?{}!\\]* | /* | *//*)
      echo "Malformed approval_paths pattern: '$1'" >&2; exit 2 ;;
  esac
  case "$p" in */*) ;; *) [ "$p" = "**" ] || [ "$anchored" -eq 1 ] || p="**/$p" ;; esac
  # Check each segment, and collapse `**/**` (it means the same as `**`).
  local IFS=/
  for seg in $p; do
    case "$seg" in
      '**') case "$out" in '**' | */'**') continue ;; esac ;;
      . | ..) echo "Malformed approval_paths pattern: '$1' (no . or .. segments)" >&2; exit 2 ;;
      *'**'*) echo "Malformed approval_paths pattern: '$1' (** must be a whole segment)" >&2
              exit 2 ;;
    esac
    out="${out:+$out/}$seg"
  done
  printf '%s\n' "$out"
}

# to_regex <normalized-pattern> : prints an anchored ERE that matches the pattern and every path
# under a directory it matches.
to_regex() {
  local segs=() n i seg re="" c j glued=1
  local IFS=/
  # Unquoted on purpose: split on `/`. Globbing is off (set -f below), so `*` stays literal.
  # shellcheck disable=SC2206
  segs=($1)
  n=${#segs[@]}
  for ((i = 0; i < n; i++)); do
    seg="${segs[i]}"
    if [ "$seg" = "**" ]; then
      if [ "$n" -eq 1 ]; then re=".*"
      elif [ "$i" -eq 0 ]; then re="(.*/)?"
      elif [ "$i" -eq $((n - 1)) ]; then re="$re(/.*)?"
      else re="$re/(.*/)?"
      fi
      glued=1
      continue
    fi
    [ "$glued" -eq 1 ] || re="$re/"
    glued=0
    for ((j = 0; j < ${#seg}; j++)); do
      c="${seg:j:1}"
      case "$c" in
        '*') re="${re}[^/]*" ;;
        [.^\$+\(\)\|]) re="$re\\$c" ;;
        *) re="$re$c" ;;
      esac
    done
  done
  printf '^%s(/.*)?$\n' "$re"
}

set -f
NORMALIZED=()
for p in "${PATTERNS[@]}"; do
  n="$(normalize "$p")" || exit 2
  NORMALIZED+=("$n")
done

if [ "$NORMALIZE" -eq 1 ]; then
  printf '%s\n' "${NORMALIZED[@]}"
  exit 0
fi

tmp="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 3; }
trap 'rm -rf "$tmp"' EXIT

# One line per changed file: its path, a tab, then its old path when renamed (else nothing). A
# tab or newline inside a path would split it into pieces no pattern matches, so jq fails on one
# and gh exits non-zero. `|| exit 3`: under `set -e` gh's own exit code would leak out, and gh's
# 2 would look like a malformed pattern.
gh api --paginate "repos/$REPO/pulls/$PR/files" \
  --jq '.[] | [.filename, (.previous_filename // "")]
        | if any(.[]; test("[\t\n\r]")) then error("tab or newline in a changed path")
          else join("\t") end' >"$tmp/files" \
  || { echo "Could not list the PR's changed files" >&2; exit 3; }
COUNT="$(gh pr view "$PR" --repo "$REPO" --json changedFiles --jq .changedFiles)" \
  || { echo "Could not read the PR's changed-file count" >&2; exit 3; }
case "$COUNT" in '' | *[!0-9]*) echo "Unexpected changedFiles: '$COUNT'" >&2; exit 3 ;; esac
LISTED="$(grep -c '' "$tmp/files" || true)"
# The files endpoint stops at 3000 files even with --paginate. More lines than files means a
# path held a newline.
if [ "$COUNT" -ge 3000 ] || [ "$COUNT" -ne "$LISTED" ]; then
  echo "$LISTED lines listed for $COUNT changed files" >&2
  exit 3
fi
# Backstop for the jq check: every line has exactly one tab, so none came from inside a path.
if LC_ALL=C grep -qvE $'^[^\t]*\t[^\t]*$' "$tmp/files"; then
  echo "A changed path holds a tab or newline" >&2
  exit 3
fi
tr '\t' '\n' <"$tmp/files" | { LC_ALL=C grep -v '^$' || true; } >"$tmp/paths"

found=0
for i in "${!NORMALIZED[@]}"; do
  re="$(to_regex "${NORMALIZED[i]}")"
  # C locale: match bytes, so a path that is not valid UTF-8 cannot make grep skip or fail on it.
  rc=0
  LC_ALL=C grep -E -e "$re" "$tmp/paths" >"$tmp/match" || rc=$?
  case "$rc" in
    0) found=1
       while IFS= read -r path; do printf '%s\t%s\n' "$path" "${PATTERNS[i]}"; done <"$tmp/match" ;;
    1) ;;
    *) echo "grep failed on the regex for '${PATTERNS[i]}'" >&2; exit 2 ;;
  esac
done
[ "$found" -eq 0 ] || exit 1
