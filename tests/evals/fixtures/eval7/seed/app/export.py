"""Exporter batching."""

from app import config


def batches(items):
    """Items in order, in lists of one batch each; the last may be shorter."""
    items = list(items)
    return [items[i:i + config.PAGE_SIZE] for i in range(0, len(items), config.PAGE_SIZE)]
