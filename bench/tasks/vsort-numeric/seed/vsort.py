#!/usr/bin/env python3
"""Sort dotted version strings (1.2.3) read one per line from stdin, oldest first."""
import sys


def version_key(version):
    """Return the sort key for one dotted version string."""
    return version.strip().split(".")


def sort_versions(versions):
    """Return the versions sorted oldest first."""
    return sorted(versions, key=version_key)


def main():
    versions = [line.strip() for line in sys.stdin if line.strip()]
    for version in sort_versions(versions):
        print(version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
