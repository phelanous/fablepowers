import unittest

from app import config


class ConfigTest(unittest.TestCase):
    def test_sizes_are_positive_ints(self):
        for name in ("page", "batch"):
            self.assertIsInstance(config.SIZES[name], int)
            self.assertGreater(config.SIZES[name], 0)


if __name__ == "__main__":
    unittest.main()
