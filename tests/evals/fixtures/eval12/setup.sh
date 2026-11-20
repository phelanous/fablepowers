#!/usr/bin/env bash
# Branch feat/demo with its seeded ledger, state "capfix": cycle 1's capped
# fix integration-3 committed and logged at HEAD, not yet verified (see
# ../eval11/branch.sh). Runs in the fixture repo; env: PLUGIN_ROOT, OUT, FIXTURE.
set -euo pipefail
bash "$FIXTURE/../eval11/branch.sh" capfix
