import sys

sys.path.insert(0, ".")
from util.base import ident  # noqa: E402

assert ident(1) == 1
