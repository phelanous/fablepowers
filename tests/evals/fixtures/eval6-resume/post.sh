#!/usr/bin/env bash
# Record whether the pre-existing T2 commit ended up merged into main.
set -uo pipefail
if git merge-base --is-ancestor "$(cat "$OUT/t2-sha.txt")" main 2>/dev/null; then
  echo yes > "$OUT/t2-merged.txt"
else
  echo no > "$OUT/t2-merged.txt"
fi
