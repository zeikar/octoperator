#!/usr/bin/env python3
"""Print the versions on stdin that satisfy an npm-style range: semver.py RANGE < versions.txt

A range is one or more comparators separated by spaces, and a version must satisfy all of them:

    1.2.3                  exactly 1.2.3
    >=1.2.3 >1.2.3 <=1.2.3 <1.2.3
    ~1.2.3                 patch updates: >=1.2.3 <1.3.0
    ^1.2.3                 updates that keep the major version: >=1.2.3 <2.0.0
"""
import operator
import re
import sys

VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)")
OPS = {"=": operator.eq, ">=": operator.ge, ">": operator.gt, "<=": operator.le, "<": operator.lt}


def parse(version):
    """Return MAJOR.MINOR.PATCH as a tuple of ints."""
    m = VERSION.fullmatch(version.strip())
    if not m:
        raise ValueError(f"bad version: {version!r}")
    return tuple(int(part) for part in m.groups())


def bounds(comparator):
    """Return the (operator, version) pairs that one comparator stands for."""
    for op in (">=", "<=", ">", "<"):
        if comparator.startswith(op):
            return [(op, parse(comparator[len(op):]))]
    if comparator.startswith("~"):
        major, minor, patch = parse(comparator[1:])
        return [(">=", (major, minor, patch)), ("<", (major, minor + 1, 0))]
    if comparator.startswith("^"):
        major, minor, patch = parse(comparator[1:])
        return [(">=", (major, minor, patch)), ("<", (major + 1, 0, 0))]
    return [("=", parse(comparator))]


def satisfies(version, spec):
    """Whether version satisfies every comparator in the range spec."""
    v = parse(version)
    return all(OPS[op](v, bound) for comp in spec.split() for op, bound in bounds(comp))


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("usage: semver.py RANGE < versions.txt", file=sys.stderr)
        return 2
    try:
        for comparator in args[0].split():
            bounds(comparator)
        for line in sys.stdin:
            if line.strip() and satisfies(line, args[0]):
                print(line.strip())
    except ValueError as err:
        print(f"semver: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
