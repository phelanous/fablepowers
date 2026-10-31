# slugify

**Status:** approved by the user.

## What

`textkit.slug.slugify(title)` turns a page title into a URL slug: lower case, every run of characters other than `a-z` and `0-9` replaced by one `-`, and no leading or trailing `-`. `slugify("Hello, World!") == "hello-world"`.

## How we'll know it works

Unit tests in `tests/test_slug.py`, plus the existing browser e2e step (`tests/e2e.sh`), which checks the slug of the page title.
