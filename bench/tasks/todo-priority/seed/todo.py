#!/usr/bin/env python3
"""A small to-do list: todo.py add TEXT..., todo.py list, todo.py done ID."""
import argparse
import sys

import store


def format_item(item):
    """One line of `list` output: `<id> [ ] <text>`, or `[x]` when done."""
    return f"{item['id']} [{'x' if item['done'] else ' '}] {item['text']}"


def main(argv=None):
    parser = argparse.ArgumentParser(description="A small to-do list.")
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("add", help="add an item")
    add.add_argument("text", nargs="+", help="what to do")
    commands.add_parser("list", help="print every item")
    done = commands.add_parser("done", help="mark an item done")
    done.add_argument("id", type=int, help="the item's id")
    args = parser.parse_args(argv)

    data = store.load()
    if args.command == "add":
        item = store.add(data, " ".join(args.text))
        store.save(data)
        print(f"added {item['id']}")
    elif args.command == "list":
        for item in sorted(data["items"], key=lambda item: item["id"]):
            print(format_item(item))
    else:
        item = store.find(data, args.id)
        if item is None:
            print(f"todo: no item {args.id}", file=sys.stderr)
            return 1
        item["done"] = True
        store.save(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
