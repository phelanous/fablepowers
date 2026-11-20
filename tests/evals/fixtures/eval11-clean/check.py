"""Eval 11, clean state: review cycle 1 ended at the integration review with
no must-fix and no re-reviews, then the same later commit. The assertions
are eval11's (see ../eval11/check.py)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "eval11"))
import check as eval11  # noqa: E402

if __name__ == "__main__":
    sys.exit(eval11.run("eval11-clean"))
