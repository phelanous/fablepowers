#!/usr/bin/env bash
# Runs the Pi extension tests (tests/pi/*.test.mjs) with `node --test`; the
# extension is TypeScript (pi/fablepowers.ts), loaded through Node's type stripping.
# Skips with a message (exit 0) when node is not installed.
set -euo pipefail
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not found; the Pi extension tests need Node.js (node --test)."
  exit 0
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
exec node --test "$SCRIPT_DIR"/*.test.mjs
