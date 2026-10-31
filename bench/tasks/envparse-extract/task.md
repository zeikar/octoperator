---
id: envparse-extract
kind: chore
difficulty: medium
---
# refactor: move the duplicated .env parser into one envparse module

`envcheck.py` and `envdump.py` each carry their own copy of `parse_env`. The copies are the same
today, but the next fix will land in one and be missed in the other. Move the parser into a
module both tools share.

## Acceptance criteria

- A new module `envparse.py`, next to the two tools, has a function `parse(text)` that returns
  exactly what `parse_env(text)` returns today, for any input
- `envcheck.py` and `envdump.py` both get their settings from `envparse.parse`, and neither keeps
  a parser of its own
- Both tools print the same output and exit with the same status as before, for any input
- The parser's tests move to `tests/test_envparse.py` and test `envparse.parse`; `make test`
  passes
- This is a refactor: no behavior changes, including the edge cases (quotes, `export`, `#`
  lines, repeated keys)
