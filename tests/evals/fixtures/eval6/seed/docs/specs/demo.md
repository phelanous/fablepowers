# mathx: add, mul and square

**Status:** approved by the user.

## What

Three functions in the `mathx` package, each in its own module:

1. `mathx.add.add(a, b)` returns `a + b`.
2. `mathx.mul.mul(a, b)` returns `a * b`.
3. `mathx.square.square(x)` returns `x * x`, computed by calling `mathx.mul.mul(x, x)`.

## How we'll know it works

Unit tests per function under `tests/`, run by `bash tests/run-all.sh`.
