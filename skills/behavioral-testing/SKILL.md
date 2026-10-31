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
2. Run the tests covering that behavior. **At least one must fail.**
3. If nothing fails, the behavior is untested no matter how green the suite is. Write the missing test before proceeding.
4. Restore the code, confirm green.

Do this for every behavior the spec calls out as a success criterion, and for every configurable knob (see below). Cheap behaviors in the same function can share one mutation pass — use judgment, but bias toward checking; the check costs seconds and the alternative cost us a shipped inert feature.

## Which tests to run, and when

- **While iterating,** run the tests covering the files the task touches, not the whole suite.
- **Per mutant,** run only the tests covering the mutated behavior. Run mutants one at a time: they share one worktree's files, so two at once break each other's runs.
- **The full suite,** browser e2e included, runs once before commit, plus once more after any fix made in response to that run. A green targeted run is not a substitute for it.
- **The report says which runs were targeted and which were full,** so a reader can tell a mutant's run from the run that gates the commit.

## Waiting on a long run

These wait rules apply to every agent, the orchestrator included, whenever a run may take longer than a single tool call allows.

1. Start the run in the background with output to a file and an exit-status marker:

   ```bash
   OUT="<scratch-dir>/suite.log"; rm -f "$OUT" "$OUT.done"
   ( <test command>; echo "exit $?" > "$OUT.done" ) > "$OUT" 2>&1 &
   ```

2. Wait on that marker, or that PID, in separate calls, each kept under the harness's tool timeout:

   ```bash
   timeout 540 bash -c "until [ -e '$OUT.done' ]; do sleep 5; done"
   ```

   Repeat the call until the marker exists, then read the marker and the output.
3. Never wait with `pgrep -f <pattern>`, and never with a sleep loop that has no completion condition. A pattern match can latch onto someone else's process (another agent's `playwright test`, a stale run) and wait on work that isn't yours.
4. The overall wait is capped at the plan's stated suite budget, or 30 minutes when the plan states none. At the cap, report the hang with the tail of the output, and stop waiting.

A harness reference may name a native mechanism in place of the marker once it is verified to reach a subagent. The marker pattern is the portable default.

## Why this replaces test-first

Past-session evidence: strict TDD produced ritual compliance (RED via `ModuleNotFoundError`, tests written from the same plan as the code) and still let the worst bug through — a tuning parameter that a test suite "covered" by asserting grid *structure* while the knob changed nothing. When one mind writes plan, test, and code in a single intent, test-first ordering doesn't buy independence. Proven-to-fail does.

## Anti-patterns to reject in your own tests

- **Structure-asserting tests:** checking shape/keys/types of output without checking values respond to inputs. The inert-knob failure mode.
- **Config knobs without a differential test:** any parameter that claims to change behavior needs a test asserting two different values produce different results.
- **Mock-echo tests:** asserting a mock was called with the arguments you just wrote. Test the seam's observable effect where possible.
- **Mirror assertions:** an expected value computed by the code under test (or its helpers) — both sides move together, so the test can't fail. Derive expectations by hand: a literal or a hand-checked fixture.
- **Change detectors:** asserting a constant equals itself, exact wording, private structure. They fail on intentional redesign and sleep through bugs. Test the behavior that depends on the decision: not `MAX_RETRIES == 5` but "a failing call is retried 5 times, never a 6th".
- **The string-presence trap:** grepping a script's, prompt's, or skill's text instead of running it proves only that the source is the source. Run the script against controlled inputs and assert its effects; for prose, the observable is the behavior it produces in the agent that reads it.
- **Testing the plan, not the spec:** if a plan detail and a spec behavior conflict, the spec wins; test the behavior.

## Bug fixes

Reproduce first: write the test that fails on the current code because of the bug, then fix. (For bugs, test-first isn't ritual — the failing test IS the reproduction, and it's the one case where ordering is genuinely load-bearing.)

## Strict-tier implementers

`fablepowers:strict-implementer` subagents follow classic red-green TDD via `prompts/implementer-strict.md` in the `fablepowers:subagent-execution` skill directory — the ritual earns its cost there. The mutation check still applies to their output; the spec-checker samples it.
