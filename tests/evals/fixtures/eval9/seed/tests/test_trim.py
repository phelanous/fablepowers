import unittest

from textkit.trim import trim


class TrimTest(unittest.TestCase):
    def test_trim(self):
        self.assertEqual(trim("  a "), "a")


if __name__ == "__main__":
    unittest.main()
