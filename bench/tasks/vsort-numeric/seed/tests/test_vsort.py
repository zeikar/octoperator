import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import vsort  # noqa: E402


class SortVersionsTest(unittest.TestCase):
    def test_sorts_oldest_first(self):
        self.assertEqual(
            vsort.sort_versions(["1.2.0", "1.0.0", "1.1.0"]),
            ["1.0.0", "1.1.0", "1.2.0"],
        )

    def test_major_version_wins(self):
        self.assertEqual(vsort.sort_versions(["2.0.0", "1.9.9"]), ["1.9.9", "2.0.0"])

    def test_empty_list(self):
        self.assertEqual(vsort.sort_versions([]), [])


if __name__ == "__main__":
    unittest.main()
