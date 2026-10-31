import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import linecount  # noqa: E402


class CountLinesTest(unittest.TestCase):
    def test_counts_newline_terminated_lines(self):
        self.assertEqual(linecount.count_lines("one\ntwo\n"), 2)

    def test_empty_text_has_no_lines(self):
        self.assertEqual(linecount.count_lines(""), 0)

    def test_blank_lines_count(self):
        self.assertEqual(linecount.count_lines("\n\n"), 2)

    def test_carriage_return_does_not_end_a_line(self):
        # Progress bars redraw with \r; like `wc -l`, that is still one line.
        self.assertEqual(linecount.count_lines("10%\r50%\r100%\n"), 1)

    def test_crlf_is_one_line_ending(self):
        self.assertEqual(linecount.count_lines("one\r\ntwo\r\n"), 2)


class MainTest(unittest.TestCase):
    def write(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, newline="") as fh:
            fh.write(text)
        self.addCleanup(os.remove, fh.name)
        return fh.name

    def test_prints_counts_and_total(self):
        a, b = self.write("1\n2\n"), self.write("3\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(linecount.main([a, b]), 0)
        self.assertEqual(out.getvalue(), f"2 {a}\n1 {b}\n3 total\n")

    def test_no_files_is_a_usage_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(linecount.main([]), 2)


if __name__ == "__main__":
    unittest.main()
