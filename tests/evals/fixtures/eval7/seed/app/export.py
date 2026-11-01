"""Exporter batching."""

from app import config


def batches(items):
    """Items in order, in lists of one batch each; the last may be shorter."""
    items = list(items)
    size = config.SIZES["batch"]
    return [items[i:i + size] for i in range(0, len(items), size)]
