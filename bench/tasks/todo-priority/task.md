---
id: todo-priority
kind: feature
difficulty: medium
---
# feat: give to-do items a priority

Every item has the same weight today, so in a long list the urgent ones get lost among the rest.
Let each item have a priority, and list the urgent ones first.

## Acceptance criteria

- `todo.py add --priority high|normal|low TEXT...` sets the new item's priority; without
  `--priority` it is `normal`. `add` still prints `added <id>`
- An unknown priority, such as `--priority urgent`, exits non-zero with an error on stderr and
  adds nothing
- `list` prints `high` items first, then `normal`, then `low`; items with the same priority stay
  in id order, whether or not they are done
- `normal` items' `list` lines are unchanged (`<id> [ ] <text>`); `high` and `low` lines end with
  ` (high)` or ` (low)`, for example `3 [ ] fix the roof (high)`
- Lists saved before this change, whose items have no priority, still load, and their items are
  `normal`
- `README.md` documents `--priority` and the new `list` order, and `make test` passes with tests
  for the new behavior
