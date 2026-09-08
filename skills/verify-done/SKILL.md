---
name: verify-done
description: Use when about to claim anything is done, fixed, passing, or working - RIGID gate; run the verification and read the output before making the claim.
---

# Verify Done — RIGID GATE

**No success claim without fresh execution evidence.** The other of the two rigid gates. (Condensed from superpowers:verification-before-completion, which this replaces.)

## The rule

Before saying "done", "fixed", "passing", "working", or committing/PRing with that implication:

1. **Identify the command that would prove the claim** — test suite, build, lint, typecheck, the actual app doing the actual thing.
2. **Run it now.** Not from memory of an earlier run — the code has changed since then.
3. **Read the output.** All of it. Exit code 0 with a warning you didn't read is not verification.
4. **Report what the output says**, not what you expected it to say. If it fails, the honest report IS the deliverable: what failed, output included.

## Claim ↔ evidence table

| Claim | Required evidence |
|---|---|
| "Tests pass" | Full suite run just now, count read from output |
| "Fixed the bug" | Reproduction case run just now, observed passing |
| "Feature works" | Feature exercised end-to-end just now |
| "Builds / typechecks / lints clean" | The command, run just now, output read |
| "Doesn't break X" | X's tests (or X itself) run just now |

## Red flags in your own drafting

Catch yourself writing: "should work", "should now pass", "this fixes", "I've verified" (past run), "tests are passing" (stale run). Each one means: stop, run the command, then finish the sentence with what actually happened.
