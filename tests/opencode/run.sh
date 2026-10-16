#!/usr/bin/env bash
# Runs the OpenCode plugin tests (tests/opencode/*.test.mjs) with `node --test`.
# Skips with a message (exit 0) when node is not installed.
set -euo pipefail
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not found; the OpenCode plugin tests need Node.js (node --test)."
  exit 0
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
exec node --test "$SCRIPT_DIR"/*.test.mjs
