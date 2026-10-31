# envtools

Two small tools for `.env` files:

- `envcheck.py FILE KEY...` checks that every `KEY` is set to a non-empty value, and exits 1
  listing the missing ones.
- `envdump.py FILE [--json]` prints the settings as sorted `KEY=value` lines, or as JSON.

## Format

One `KEY=value` per line. Blank lines and lines starting with `#` are skipped, and so are lines
without `=`. An `export ` prefix is dropped, and one pair of matching quotes around the value is
removed. A key that appears twice keeps its last value.

## Tests

    make test
