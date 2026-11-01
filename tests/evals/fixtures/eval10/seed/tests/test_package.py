import unittest

import palette


class PackageTest(unittest.TestCase):
    def test_imports(self):
        self.assertTrue(palette)


if __name__ == "__main__":
    unittest.main()
