"""List view paging."""

from app import config


def first_page(items):
    """The first page of items, as a list."""
    return list(items)[:config.PAGE_SIZE]
