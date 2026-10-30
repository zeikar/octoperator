#!/usr/bin/env python3
"""Print how often each word appears in a text file, most frequent first."""
import argparse
import re
import sys
from collections import Counter

WORD = re.compile(r"[a-z0-9']+")


def count_words(text):
    """Return (word, count) pairs: most frequent first, ties in alphabetical order."""
    counts = Counter(WORD.findall(text.lower()))
    return sorted(counts.items(), key=lambda item: (-item[1], item[0]))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Count word frequencies in a text file.")
    parser.add_argument("file", help="text file to read, or - for stdin")
    args = parser.parse_args(argv)

    if args.file == "-":
        text = sys.stdin.read()
    else:
        with open(args.file, encoding="utf-8") as fh:
            text = fh.read()

    for word, count in count_words(text):
        print(f"{count} {word}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
