# shout and clamp

**Status:** approved by the user.

## What

1. `util.strings.shout(s)` returns `s.upper() + "!"`.
2. `util.nums.clamp(x, lo, hi)` returns `x` limited to `[lo, hi]`.

Each gets an e2e check under `e2e/`, run by `bash tests/e2e.sh`, which uses the fixed port 4500.

## How we'll know it works

Unit tests under `tests/` and one e2e check per function, all run by `bash tests/run-all.sh`.
