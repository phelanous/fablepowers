---
name: behavioral-testing
description: Use when writing tests for any feature or bugfix - replaces TDD-as-ritual with a rigid outcome (every spec behavior has a test proven to fail when broken) and free ordering.
---

# Behavioral Testing

## The rigid outcome

**Every behavior in the spec has a test that fails when that behavior is broken — and you have demonstrated it, not assumed it.**

Ordering (test-first vs. test-with) is free for frontier models. The demonstration is not.

## The mutation check

For each core behavior, after implementation and tests are green:

1. Break the behavior — flip the comparison, hard-code the return, skip the branch, zero the parameter.
2. Run the tests. **At least one must fail.**
3. If nothing fails, the behavior is untested no matter how green the suite is. Write the missing test before proceeding.
4. Restore the code, confirm green.

Do this for every behavior the spec calls out as a success criterion, and for every configurable knob (see below). Cheap behaviors in the same function can share one mutation pass — use judgment, but bias toward checking; the check costs seconds and the alternative cost us a shipped inert feature.

## Why this replaces test-first

Past-session evidence: strict TDD produced ritual compliance (RED via `ModuleNotFoundError`, tests written from the same plan as the code) and still let the worst bug through — a tuning parameter that a test suite "covered" by asserting grid *structure* while the knob changed nothing. When one mind writes plan, test, and code in a single intent, test-first ordering doesn't buy independence. Proven-to-fail does.

## Anti-patterns to reject in your own tests

- **Structure-asserting tests:** checking shape/keys/types of output without checking values respond to inputs. The inert-knob failure mode.
- **Config knobs without a differential test:** any parameter that claims to change behavior needs a test asserting two different values produce different results.
- **Mock-echo tests:** asserting a mock was called with the arguments you just wrote. Test the seam's observable effect where possible.
- **Testing the plan, not the spec:** if a plan detail and a spec behavior conflict, the spec wins; test the behavior.

## Bug fixes

Reproduce first: write the test that fails on the current code because of the bug, then fix. (For bugs, test-first isn't ritual — the failing test IS the reproduction, and it's the one case where ordering is genuinely load-bearing.)

## Strict-tier implementers

`fablepowers:strict-implementer` subagents follow classic red-green TDD via `fablepowers:subagent-execution`'s `prompts/implementer-strict.md` — the ritual earns its cost there. The mutation check still applies to their output; the spec-checker samples it.
