# Bigger pages and export batches

**Status:** approved by the user.

## What

1. **List view:** `app.list_view.first_page(items)` returns the first 50 items. Today it returns 10; users asked for 50 per page.
2. **Exporter:** `app.export.batches(items)` splits items into lists of 100 (the last may be shorter). Today the batches hold 10; the export service now takes batches of exactly 100.

## How we'll know it works

Unit tests per module under `tests/`, run by `bash tests/run-all.sh`.
