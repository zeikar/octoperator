---
id: snap-spaces
kind: bug
difficulty: easy
---
# fix: snap.sh fails on file names with spaces

`snap.sh` splits paths on whitespace, so a config file such as `my app.conf` is never backed up,
and the run fails. A `SRC` or `DEST` directory with a space in its name breaks it the same way.

## Steps to reproduce

    mkdir -p 'conf dir' && echo port=1 > 'conf dir/my app.conf'
    ./snap.sh 'conf dir' backups; echo "exit $?"

## Actual

    basename: extra operand 'app.conf'
    Try 'basename --help' for more information.
    cp: target 'backups/.bak': No such file or directory
    exit 1

## Expected

`backups/my app.conf.bak` holds a copy of `my app.conf`, and the exit status is 0.

## Acceptance criteria

- Any file name works: spaces (also two in a row), quotes, `*`, and a leading `-`
- `SRC` and `DEST` may contain spaces too
- Nothing else changes: only regular `*.conf` files directly in `SRC` are copied, `DEST` is
  created if needed, a `SRC` with no `*.conf` files exits 0 and copies nothing, and a wrong
  number of arguments exits 2
- `make test` passes, with a regression test for this bug
