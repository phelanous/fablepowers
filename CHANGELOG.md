# Changelog

## 0.2.0 — 2026-09-24

From the second log audit (40 sessions on 0.1.0; full numbers in `docs/rationale.md`).

- **A design brief precedes the approval ask.** `design-spec` ends with a phone-readable brief under six fixed headings (What changes, Decisions I made, Not doing, Risk, Open the spec if, Verified by), then one question with exactly two options, Approve and Changes needed. 16 of 42 approval asks under 0.1.0 had no design summary in the turn; design variants had moved into the options.
- **Fix-round dispatches carry per-finding test obligations.** When an implementer fixes review findings, each must-fix finding's failure scenario is a test that fails before the fix and passes after, with the evidence reported per finding. Re-review must-fixes were often regressions from the fix commit.
- **`docs/rationale.md` gains the second check-in** (2026-09-24): delegation fixed (subagent share of output 59%, was 22%), approval-ask and review-yield numbers, and the decisions above.

## 0.1.0 — 2026-09-07

First release. Packages the personal superpowers fork as an installable plugin.

**Contents**

- Seven forked skills: `workflow`, `design-spec`, `implementation-plan`, `subagent-execution`, `behavioral-testing`, `integration-review`, `verify-done`.
- Three skills vendored from superpowers 5.0.7 (MIT, Jesse Vincent; see `NOTICE`) with cross-references retargeted: `systematic-debugging`, `using-git-worktrees`, `finishing-a-development-branch`.
- Three agents with pinned models: `implementer` (Opus), `strict-implementer` (Sonnet), `reviewer` (Opus).
- A SessionStart hook that loads the workflow map, replacing the CLAUDE.md preamble the fork previously needed.
- `docs/rationale.md` (the evidence) and `scripts/analyze_delegation.py` (the measurement harness).

**Design decisions from the 2026-09-07 log audit** (27 fork-era sessions; full numbers in `docs/rationale.md`)

- **Roles become agents with pinned models.** `model` was unset on 101 of 114 `Agent` spawns, so subagents silently inherited the orchestrator's model and effort. The model now lives in the agent definition, not in whatever prompt gets written at dispatch time.
- **The orchestrator never implements a plan task.** Its model produced 97% of fork-era output tokens — 78% in the main loop itself, the rest in subagents that inherited its model; 9 of 13 plan headers read "Implementer tier: frontier (orchestrator implements directly)". The tier wording invited it, so the tier wording is gone. The only code the orchestrator writes itself is a one-line fix inside a review loop, and it says so.
- **The design-approval ask stands alone.** The checkpoint held in 17 of 19 sessions; both misses had the same shape — the approval question bundled with an open design question. The ask is now its own single-question call or its own message, and an answer that picks an option is never approval.
- **Integration re-reviews are capped at two rounds.** The gate earns its cost (~10 of 18 first passes found a blocker), but one feature ran six re-review rounds. After the cap, remaining must-fix items are fixed, `fablepowers:verify-done` runs, and the report to the user states that the loop was capped and what remained.
