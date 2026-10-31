# todo

A small to-do list kept in a JSON file: `$TODO_FILE`, or `todo.json` in the current directory.

## Usage

    python3 todo.py add buy milk     # prints "added 1"
    python3 todo.py list             # "1 [ ] buy milk"
    python3 todo.py done 1           # marks item 1 done: "1 [x] buy milk"

`list` prints one line per item, `<id> [ ] <text>`, with `[x]` for done items, in id order.

## Tests

    make test
