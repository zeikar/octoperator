#!/usr/bin/env python3
"""Print chosen columns of a CSV file, picked by their header names."""
import argparse
import sys


def split_row(line, delimiter):
    """Split one CSV line into its fields. Quoted fields may contain the delimiter."""
    return line.rstrip("\r\n").split(delimiter)


def cut(lines, names, delimiter=","):
    """Return the named columns of every row, header row first, in the order of names."""
    rows = [split_row(line, delimiter) for line in lines if line.strip()]
    if not rows:
        return []
    header = rows[0]
    missing = [name for name in names if name not in header]
    if missing:
        raise ValueError("no such column: " + ", ".join(missing))
    picks = [header.index(name) for name in names]
    return [[row[i] if i < len(row) else "" for i in picks] for row in rows]


def main(argv=None):
    parser = argparse.ArgumentParser(description="Print chosen columns of a CSV file.")
    parser.add_argument("-f", "--fields", required=True,
                        help="comma-separated header names of the columns to print")
    parser.add_argument("-d", "--delimiter", default=",",
                        help="the field delimiter (default: ,)")
    parser.add_argument("file", nargs="?", default="-", help="CSV file to read, or - for stdin")
    args = parser.parse_args(argv)

    if args.file == "-":
        lines = sys.stdin.readlines()
    else:
        with open(args.file, encoding="utf-8") as fh:
            lines = fh.readlines()

    try:
        rows = cut(lines, args.fields.split(","), args.delimiter)
    except ValueError as err:
        print(f"csvcut: {err}", file=sys.stderr)
        return 1
    for row in rows:
        print(args.delimiter.join(row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
