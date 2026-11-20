#!/usr/bin/env bash
# The finished feature branch feat/demo with its seeded ledger, state "rebase"
# (see ../eval11/branch.sh). Runs in the fixture repo; env: PLUGIN_ROOT, OUT, FIXTURE.
set -euo pipefail
bash "$FIXTURE/../eval11/branch.sh" rebase
