import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import semver  # noqa: E402


def matching(spec, versions):
    return [v for v in versions if semver.satisfies(v, spec)]


class SatisfiesTest(unittest.TestCase):
    def test_exact(self):
        self.assertEqual(matching("1.2.3", ["1.2.3", "1.2.4"]), ["1.2.3"])

    def test_comparisons(self):
        self.assertEqual(matching(">=1.2.0 <1.3.0", ["1.1.9", "1.2.0", "1.2.9", "1.3.0"]),
                         ["1.2.0", "1.2.9"])
        self.assertEqual(matching(">1.0.0", ["1.0.0", "1.0.1"]), ["1.0.1"])
        self.assertEqual(matching("<=1.0.0", ["1.0.0", "1.0.1"]), ["1.0.0"])

    def test_tilde(self):
        self.assertEqual(matching("~1.2.3", ["1.2.2", "1.2.3", "1.2.9", "1.3.0"]),
                         ["1.2.3", "1.2.9"])

    def test_caret(self):
        self.assertEqual(matching("^1.2.3", ["1.2.2", "1.2.3", "1.9.0", "2.0.0"]),
                         ["1.2.3", "1.9.0"])

    def test_parts_compare_as_numbers(self):
        self.assertEqual(matching(">=1.10.0", ["1.9.0", "1.10.0"]), ["1.10.0"])

    def test_bad_version(self):
        with self.assertRaises(ValueError):
            semver.satisfies("1.2", "^1.0.0")


if __name__ == "__main__":
    unittest.main()
