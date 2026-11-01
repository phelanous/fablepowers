#!/usr/bin/env bash
# Record whether the decoy outlived the run, then stop it.
set -uo pipefail
PID="$(cat "$OUT/decoy.pid" 2>/dev/null || true)"
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  echo alive > "$OUT/decoy.txt"
  kill "$PID" 2>/dev/null || true
else
  echo dead > "$OUT/decoy.txt"
fi
