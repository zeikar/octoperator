---
id: mdtable-rename-flag
kind: chore
difficulty: easy
---
# chore: rename mdtable's --sep to --delimiter, keeping --sep as a deprecated alias

Our other tools call this option `--delimiter` (short form `-d`), but `mdtable.py` calls it
`--sep`, so people keep typing the wrong one. Rename it. Existing scripts pass `--sep`, so it has
to keep working for now, with a warning that points to the new name.

## Acceptance criteria

- `--delimiter X` and `-d X` set the field separator; without either, it is still `,`
- `--sep X` still works and prints the same table as `--delimiter X`. It also prints a warning on
  stderr that says `--sep` is deprecated and names `--delimiter`, and it still exits 0
- Nothing is printed on stderr when `--sep` is not used
- `python3 mdtable.py --help` shows `--delimiter`
- `README.md` documents `--delimiter`, and mentions `--sep` only as deprecated
- `CHANGELOG.md` gets two entries under `## [Unreleased]`: one under `### Added` for
  `--delimiter`/`-d`, and one under `### Deprecated` for `--sep`
- `make test` passes, with tests for `--delimiter`, `-d`, and the `--sep` warning
