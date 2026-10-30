# vsort

Sorts dotted version strings, oldest first. Reads one version per line from stdin and skips blank
lines.

## Usage

    git tag --list 'v*' | sed 's/^v//' | python3 vsort.py

## Tests

    make test
