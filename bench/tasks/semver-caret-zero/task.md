---
id: semver-caret-zero
kind: bug
difficulty: medium
---
# fix: ^0.x ranges let breaking releases through

For versions below 1.0.0, a minor bump is a breaking change, so npm reads `^0.2.3` as
`>=0.2.3 <0.3.0`. `semver.py` always lets everything below the next major through instead, so
`^0.2.3` accepts `0.3.0` and `0.9.0`.

## Steps to reproduce

    printf '0.2.3\n0.2.9\n0.3.0\n0.9.0\n' | python3 semver.py '^0.2.3'

## Actual

    0.2.3
    0.2.9
    0.3.0
    0.9.0

## Expected

    0.2.3
    0.2.9

## Acceptance criteria

- A caret range keeps the leftmost non-zero part of its version fixed, as npm does:
  - `^1.2.3` is still `>=1.2.3 <2.0.0`
  - `^0.2.3` is `>=0.2.3 <0.3.0`
  - `^0.0.3` is `>=0.0.3 <0.0.4`, and `^0.0.0` matches only `0.0.0`
- Exact versions, `>=` / `>` / `<=` / `<`, `~`, and space-separated ranges work as before
- The README's comparator table gets a row for `^0.2.3` and one for `^0.0.3`, each giving its
  range in the `Matches` column (`>=0.2.3 <0.3.0`, `>=0.0.3 <0.0.4`)
- `make test` passes, with regression tests for this bug
