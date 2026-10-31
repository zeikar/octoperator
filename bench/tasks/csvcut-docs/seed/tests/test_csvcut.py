import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import csvcut  # noqa: E402

PEOPLE = ["name,email,city\n", "Ada,ada@example.com,London\n", "Linus,linus@example.com,Helsinki\n"]


class CutTest(unittest.TestCase):
    def test_picks_columns_by_name(self):
        self.assertEqual(
            csvcut.cut(PEOPLE, ["name", "city"]),
            [["name", "city"], ["Ada", "London"], ["Linus", "Helsinki"]],
        )

    def test_keeps_the_order_asked_for(self):
        self.assertEqual(csvcut.cut(PEOPLE, ["city", "name"])[1], ["London", "Ada"])

    def test_other_delimiter(self):
        self.assertEqual(csvcut.cut(["a;b\n", "1;2\n"], ["b"], ";"), [["b"], ["2"]])

    def test_unknown_column(self):
        with self.assertRaises(ValueError):
            csvcut.cut(PEOPLE, ["phone"])

    def test_short_row_gives_empty_field(self):
        self.assertEqual(csvcut.cut(["a,b\n", "1\n"], ["b"]), [["b"], [""]])

    def test_blank_lines_are_skipped(self):
        self.assertEqual(csvcut.cut(["a\n", "\n", "1\n"], ["a"]), [["a"], ["1"]])


if __name__ == "__main__":
    unittest.main()
