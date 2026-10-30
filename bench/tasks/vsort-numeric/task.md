---
id: vsort-numeric
kind: bug
difficulty: easy
---
# fix: vsort puts 1.10.0 before 1.9.0

`vsort.py` compares version parts as text, so a two-digit part sorts before a one-digit part.

## Steps to reproduce

    printf '1.10.0\n1.9.0\n1.2.0\n' | python3 vsort.py

## Actual

    1.10.0
    1.2.0
    1.9.0

## Expected

    1.2.0
    1.9.0
    1.10.0

## Acceptance criteria

- Each dot-separated part is compared as a number (`1.9.0` < `1.10.0`, `2.0.0` < `10.0.0`)
- A version that is a prefix of another sorts first (`1.2` < `1.2.1`)
- Versions are still read one per line from stdin, blank lines skipped, and printed oldest first
- `make test` passes, with a regression test for this bug
