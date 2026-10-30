---
id: wordfreq-top
kind: feature
difficulty: easy
---
# feat: add a --top N option to wordfreq

`wordfreq.py` prints every word it finds. On a long file that is hundreds of lines when you only
want the most common few.

Add a `--top N` option that prints only the `N` most frequent words, in the same order and format
as today.

## Acceptance criteria

- `python3 wordfreq.py --top 2 notes.txt` prints the first 2 lines that
  `python3 wordfreq.py notes.txt` prints
- When `N` is larger than the number of distinct words, every word is printed
- Without `--top`, the output is unchanged
- A value that is not a positive integer (`0`, `-1`, `abc`) exits non-zero with an error on
  stderr and prints nothing on stdout
- `--top` is mentioned in the README, and `make test` passes with tests for the new option
