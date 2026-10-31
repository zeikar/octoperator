# csvcut

Prints chosen columns of a CSV file, picked by their header names.

## Usage

    python3 csvcut.py -f name,email people.csv
    python3 csvcut.py -d ';' -f city people.csv
    cat people.csv | python3 csvcut.py -f email

The header row is printed first, then the chosen columns of every row, joined with the delimiter.

## Tests

    make test
