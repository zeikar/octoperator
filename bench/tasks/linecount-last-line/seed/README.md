# linecount

Counts the lines in each file, like `wc -l`, and prints a total when given more than one file.

## Usage

    python3 linecount.py notes.txt todo.txt

Each output line is `<count> <file>`, then `<count> total`:

    12 notes.txt
    3 todo.txt
    15 total

## Tests

    make test
