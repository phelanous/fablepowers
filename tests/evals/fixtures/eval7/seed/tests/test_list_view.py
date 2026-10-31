import unittest

from app.list_view import first_page


class ListViewTest(unittest.TestCase):
    def test_short_list_is_whole_page(self):
        self.assertEqual(first_page([1, 2]), [1, 2])


if __name__ == "__main__":
    unittest.main()
