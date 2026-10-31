import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import envcheck  # noqa: E402


class ParseEnvTest(unittest.TestCase):
    def test_key_value_lines(self):
        self.assertEqual(envcheck.parse_env("A=1\nB=two\n"), {"A": "1", "B": "two"})

    def test_comments_and_blank_lines_are_skipped(self):
        self.assertEqual(envcheck.parse_env("# note\n\nA=1\n"), {"A": "1"})

    def test_quotes_and_export(self):
        self.assertEqual(envcheck.parse_env("export A=\"x y\"\nB='z'\n"), {"A": "x y", "B": "z"})


class MainTest(unittest.TestCase):
    def run_main(self, text, *keys):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as fh:
            fh.write(text)
        self.addCleanup(os.remove, fh.name)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = envcheck.main([fh.name, *keys])
        return rc, out.getvalue()

    def test_all_set(self):
        self.assertEqual(self.run_main("A=1\nB=2\n", "A", "B"), (0, "ok\n"))

    def test_missing_and_empty(self):
        self.assertEqual(self.run_main("A=\n", "A", "B"), (1, "missing: A\nmissing: B\n"))


if __name__ == "__main__":
    unittest.main()
