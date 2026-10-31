import unittest

from util.base import ident


class BaseTest(unittest.TestCase):
    def test_ident(self):
        self.assertEqual(ident("a"), "a")


if __name__ == "__main__":
    unittest.main()
