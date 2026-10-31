import unittest

from app import config


class ConfigTest(unittest.TestCase):
    def test_page_size_is_positive_int(self):
        self.assertIsInstance(config.PAGE_SIZE, int)
        self.assertGreater(config.PAGE_SIZE, 0)


if __name__ == "__main__":
    unittest.main()
