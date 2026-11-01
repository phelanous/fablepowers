#!/usr/bin/env bash
# Full suite: unit tests, then the browser e2e step (about 3 minutes).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -t . -q
bash tests/e2e.sh
