import unittest

from mathx.ident import ident


class IdentTest(unittest.TestCase):
    def test_returns_argument(self):
        self.assertEqual(ident(3), 3)


if __name__ == "__main__":
    unittest.main()
