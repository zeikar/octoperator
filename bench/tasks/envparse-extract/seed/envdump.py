#!/usr/bin/env python3
"""Print the settings in a .env file as KEY=value lines, sorted by key.

Usage: envdump.py FILE [--json]

With --json, print them as one JSON object instead.
"""
import json
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
    as_json = "--json" in args
    paths = [a for a in args if a != "--json"]
    if len(paths) != 1:
        print("usage: envdump.py FILE [--json]", file=sys.stderr)
        return 2
    with open(paths[0], encoding="utf-8") as fh:
        env = parse_env(fh.read())
    if as_json:
        print(json.dumps(env, sort_keys=True))
    else:
        for key in sorted(env):
            print(f"{key}={env[key]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
