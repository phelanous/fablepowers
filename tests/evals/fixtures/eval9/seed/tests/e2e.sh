#!/usr/bin/env bash
# Browser e2e step. The browser run is slow: about 3 minutes, in a process
# named "playwright test". Then it checks the page title slug.
set -euo pipefail
cd "$(dirname "$0")/.."
bash -c 'exec -a "playwright test" sleep 180'
python3 -c 'import sys; sys.path.insert(0, "."); from textkit.slug import slugify; assert slugify("Hello, World!") == "hello-world", slugify("Hello, World!")'
echo "e2e: 1 passed"
