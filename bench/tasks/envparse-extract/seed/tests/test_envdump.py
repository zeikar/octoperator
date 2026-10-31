import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import envdump  # noqa: E402


class ParseEnvTest(unittest.TestCase):
    def test_last_value_wins(self):
        self.assertEqual(envdump.parse_env("A=1\nA=2\n"), {"A": "2"})

    def test_lines_without_equals_are_skipped(self):
        self.assertEqual(envdump.parse_env("junk\nA=1\n"), {"A": "1"})


class MainTest(unittest.TestCase):
    def run_main(self, text, *args):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as fh:
            fh.write(text)
        self.addCleanup(os.remove, fh.name)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(envdump.main([fh.name, *args]), 0)
        return out.getvalue()

    def test_sorted_lines(self):
        self.assertEqual(self.run_main("B=2\nA=1\n"), "A=1\nB=2\n")

    def test_json(self):
        self.assertEqual(self.run_main("B=2\nA=1\n", "--json"), '{"A": "1", "B": "2"}\n')


if __name__ == "__main__":
    unittest.main()
