---
id: linecount-last-line
kind: bug
difficulty: easy
---
# fix: linecount misses the last line when a file does not end with a newline

`linecount.py` counts newline characters, so a last line with no `\n` after it is not counted.
Files saved by some editors, and output captured with `printf`, often end that way.

## Steps to reproduce

    printf 'one\ntwo' > notes.txt
    python3 linecount.py notes.txt

## Actual

    1 notes.txt

## Expected

    2 notes.txt

## Acceptance criteria

- A non-empty last line without a trailing `\n` counts as a line (`one\ntwo` is 2 lines)
- Everything that is counted today is counted the same way: `one\ntwo\n` is still 2 lines, and
  an empty file is still 0
- The per-file and `total` output lines keep their format
- `make test` passes, with a regression test for this bug
