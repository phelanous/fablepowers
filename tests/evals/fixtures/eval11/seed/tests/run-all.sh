#!/usr/bin/env bash
# Full suite: every unit test under tests/.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -t . -q
