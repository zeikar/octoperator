import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import store  # noqa: E402
import todo  # noqa: E402


class TodoTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        os.environ["TODO_FILE"] = os.path.join(tmp.name, "todo.json")
        self.addCleanup(os.environ.pop, "TODO_FILE")

    def run_todo(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = todo.main(list(args))
        return rc, out.getvalue()

    def test_add_and_list(self):
        self.assertEqual(self.run_todo("add", "buy", "milk"), (0, "added 1\n"))
        self.run_todo("add", "call mom")
        self.assertEqual(self.run_todo("list"), (0, "1 [ ] buy milk\n2 [ ] call mom\n"))

    def test_done(self):
        self.run_todo("add", "buy milk")
        self.assertEqual(self.run_todo("done", "1"), (0, ""))
        self.assertEqual(self.run_todo("list"), (0, "1 [x] buy milk\n"))

    def test_done_unknown_id(self):
        self.assertEqual(self.run_todo("done", "9")[0], 1)

    def test_saved_between_runs(self):
        self.run_todo("add", "buy milk")
        self.assertEqual(store.load()["items"][0]["text"], "buy milk")


if __name__ == "__main__":
    unittest.main()
