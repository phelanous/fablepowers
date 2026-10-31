#!/usr/bin/env bash
# Browser e2e stand-in. The real one binds the fixed port 4500, so two runs at
# once collide; this stand-in runs every check in e2e/.
set -euo pipefail
cd "$(dirname "$0")/.."
sleep 2
for f in e2e/*.py; do
  [ -e "$f" ] || continue
  python3 "$f"
done
echo "e2e: ok"
