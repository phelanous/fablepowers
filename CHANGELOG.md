# Changelog

## 0.2.1 — 2026-10-09

The three vendored skills are re-based on superpowers v7.0.0, picking up fixes upstream had already made.

- **`systematic-debugging` no longer triggers extended thinking.** The skill text contained the trigger keyword, so every session that loaded it paid for extended thinking.
- **Debugging diagnostics no longer print secrets.** The environment-check example echoed the value it was checking for.
- **`find-polluter.sh` actually bisects.** It never matched a file and reported "Found 1" on empty input; it now matches and reports an honest 0. Its upstream test ships under `tests/`.
- **Pull requests work on Forgejo and GitLab.** Finishing names non-interactive `gh`, `fj` and `glab` commands, checks auth first, and falls back to the URL the forge printed on push.
- **Merging works when the base branch is checked out elsewhere.** The merge runs in the worktree that has the base branch, never by checking it out inside the feature worktree.
- **Finishing never removes worktrees it doesn't own.** Only worktrees under the project root's `.worktrees/` or `worktrees/` are cleaned up; host-owned ones such as `.claude/worktrees/` are left alone, and a refused removal is reported instead of forced.
- **Discarding work is offered only when asked for.** It is no longer an item in the standard menu.
- **`using-git-worktrees` doesn't nest worktrees.** It detects an existing linked worktree (including inside submodules), prefers the harness's native worktree tool, and places new worktrees under the project root instead of a global directory.

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
