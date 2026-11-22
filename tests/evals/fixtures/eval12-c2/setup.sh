#!/usr/bin/env bash
# Branch feat/demo with its seeded ledger, state "c2": cycle 1 capped, a later
# commit, review integration-c2 with a must-fix, then fix integration-c2-1 at
# HEAD (see ../eval11/branch.sh). Runs in the fixture repo; env: PLUGIN_ROOT,
# OUT, FIXTURE.
set -euo pipefail
bash "$FIXTURE/../eval11/branch.sh" c2
