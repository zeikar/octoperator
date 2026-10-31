import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import mdtable  # noqa: E402


class ToMarkdownTest(unittest.TestCase):
    def test_header_delimiter_and_rows(self):
        self.assertEqual(
            mdtable.to_markdown([["a", "b"], ["1", "2"]]),
            ["| a | b |", "|---|---|", "| 1 | 2 |"],
        )

    def test_short_rows_are_padded(self):
        self.assertEqual(mdtable.to_markdown([["a", "b"], ["1"]])[2], "| 1 |  |")


class MainTest(unittest.TestCase):
    def run_main(self, text, *args):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write(text)
        self.addCleanup(os.remove, fh.name)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(mdtable.main([*args, fh.name]), 0)
        return out.getvalue()

    def test_commas_by_default(self):
        self.assertEqual(self.run_main("a,b\n1,2\n"), "| a | b |\n|---|---|\n| 1 | 2 |\n")

    def test_sep(self):
        self.assertEqual(self.run_main("a;b\n1;2\n", "--sep", ";"),
                         "| a | b |\n|---|---|\n| 1 | 2 |\n")


if __name__ == "__main__":
    unittest.main()
