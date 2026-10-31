#!/usr/bin/env python3
"""Print delimited text (CSV by default) as a Markdown table. The first row is the header."""
import argparse
import sys


def to_markdown(rows):
    """Return rows (lists of cells, the header first) as the lines of a Markdown table."""
    width = max(len(row) for row in rows)
    rows = [row + [""] * (width - len(row)) for row in rows]
    lines = ["| " + " | ".join(rows[0]) + " |", "|" + "---|" * width]
    lines += ["| " + " | ".join(row) + " |" for row in rows[1:]]
    return lines


def main(argv=None):
    parser = argparse.ArgumentParser(description="Print delimited text as a Markdown table.")
    parser.add_argument("--sep", default=",", help="the field separator (default: ,)")
    parser.add_argument("file", nargs="?", default="-", help="file to read, or - for stdin")
    args = parser.parse_args(argv)

    if args.file == "-":
        text = sys.stdin.read()
    else:
        with open(args.file, encoding="utf-8") as fh:
            text = fh.read()

    rows = [line.split(args.sep) for line in text.splitlines() if line.strip()]
    if rows:
        for line in to_markdown(rows):
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
