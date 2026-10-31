#!/usr/bin/env python3
"""Check that a .env file sets every required key to a non-empty value.

Usage: envcheck.py FILE KEY...

Prints `ok` and exits 0 when every KEY is set; otherwise prints `missing: KEY` for each one that
is unset or empty, in the order given, and exits 1.
"""
import sys


def parse_env(text):
    """Parse .env text into a dict.

    One KEY=value per line. Blank lines and lines starting with # are skipped, and so are lines
    without =. An `export ` prefix is dropped. Whitespace around the key and the value is
    trimmed, and one pair of matching single or double quotes around the value is removed. A key
    that appears twice keeps its last value.
    """
    env = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        env[key] = value
    return env


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) < 2:
        print("usage: envcheck.py FILE KEY...", file=sys.stderr)
        return 2
    path, keys = args[0], args[1:]
    with open(path, encoding="utf-8") as fh:
        env = parse_env(fh.read())
    missing = [key for key in keys if not env.get(key)]
    for key in missing:
        print(f"missing: {key}")
    if not missing:
        print("ok")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
