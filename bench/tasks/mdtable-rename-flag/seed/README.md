# mdtable

Prints delimited text as a Markdown table. The first row becomes the header.

## Usage

    python3 mdtable.py people.csv
    python3 mdtable.py --sep ';' people.txt
    cut -d: -f1,7 /etc/passwd | python3 mdtable.py --sep :

`--sep` sets the field separator (default `,`).

## Tests

    make test
