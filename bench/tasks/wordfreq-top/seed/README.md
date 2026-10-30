# wordfreq

Prints how often each word appears in a text file, most frequent first. Words are lowercased, and
words with the same count are listed alphabetically.

## Usage

    python3 wordfreq.py notes.txt
    cat notes.txt | python3 wordfreq.py -

Each output line is `<count> <word>`:

    3 the
    2 and
    1 cat

## Tests

    make test
