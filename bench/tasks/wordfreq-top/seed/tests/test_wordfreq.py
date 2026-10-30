import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import wordfreq  # noqa: E402


class CountWordsTest(unittest.TestCase):
    def test_most_frequent_first(self):
        self.assertEqual(
            wordfreq.count_words("b a b c b a"),
            [("b", 3), ("a", 2), ("c", 1)],
        )

    def test_ties_are_alphabetical(self):
        self.assertEqual(wordfreq.count_words("pear apple"), [("apple", 1), ("pear", 1)])

    def test_case_and_punctuation_are_ignored(self):
        self.assertEqual(wordfreq.count_words("Hello, hello!"), [("hello", 2)])


class MainTest(unittest.TestCase):
    def test_prints_count_and_word(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write("to be or not to be")
        self.addCleanup(os.remove, fh.name)

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(wordfreq.main([fh.name]), 0)
        self.assertEqual(out.getvalue(), "2 be\n2 to\n1 not\n1 or\n")


if __name__ == "__main__":
    unittest.main()
