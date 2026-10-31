#!/usr/bin/env python3
"""Count the lines in each file, like `wc -l`, and print a total for more than one file."""
import sys


def count_lines(text):
    """Return the number of lines in text."""
    return text.count("\n")


def main(argv=None):
    paths = sys.argv[1:] if argv is None else argv
    if not paths:
        print("usage: linecount.py FILE...", file=sys.stderr)
        return 2
    total = 0
    for path in paths:
        # newline="": keep \r and \r\n as they are, so only \n ends a line.
        with open(path, encoding="utf-8", newline="") as fh:
            count = count_lines(fh.read())
        print(f"{count} {path}")
        total += count
    if len(paths) > 1:
        print(f"{total} total")
    return 0


if __name__ == "__main__":
    sys.exit(main())
