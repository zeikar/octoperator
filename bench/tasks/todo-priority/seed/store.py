"""Load and save the to-do list: a JSON file at $TODO_FILE, or ./todo.json."""
import json
import os


def path():
    """The file the list lives in."""
    return os.environ.get("TODO_FILE") or "todo.json"


def load():
    """Return the list as {"next_id": int, "items": [{"id", "text", "done"}, ...]}."""
    try:
        with open(path(), encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return {"next_id": 1, "items": []}


def save(data):
    """Write the list back, replacing the file in one step."""
    tmp = path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path())


def add(data, text):
    """Append a new open item and return it."""
    item = {"id": data["next_id"], "text": text, "done": False}
    data["items"].append(item)
    data["next_id"] += 1
    return item


def find(data, item_id):
    """Return the item with this id, or None."""
    return next((item for item in data["items"] if item["id"] == item_id), None)
