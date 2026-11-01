import unittest

from app.export import batches


class ExportTest(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(batches([]), [])


if __name__ == "__main__":
    unittest.main()
