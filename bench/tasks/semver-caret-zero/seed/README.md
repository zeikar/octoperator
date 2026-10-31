# semver

Prints the versions on stdin that satisfy an npm-style range, in the order they came in.

## Usage

    git tag --list | sed 's/^v//' | python3 semver.py '^1.2.0'
    python3 semver.py '>=1.0.0 <1.5.0' < versions.txt

A range is one or more comparators separated by spaces; a version must satisfy all of them.

| Comparator | Matches                                         |
|------------|-------------------------------------------------|
| `1.2.3`    | exactly `1.2.3`                                 |
| `>=1.2.3`  | also `>`, `<=`, and `<`                         |
| `~1.2.3`   | patch updates: `>=1.2.3 <1.3.0`                 |
| `^1.2.3`   | updates that keep the major: `>=1.2.3 <2.0.0`   |

## Tests

    make test
