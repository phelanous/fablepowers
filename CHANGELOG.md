# Changelog

## 0.3.0 — 2026-10-09

Workflow ideas from superpowers v6–v7 that fit this plugin's evidence, adapted rather than vendored. Reasons, and the upstream ideas left out, in `docs/rationale.md`.

- **Agents can't spawn agents.** `implementer`, `strict-implementer` and `reviewer` have `disallowedTools: Agent`; a sub-spawn would run on the parent's inherited model, the defect pinned agents exist to fix.
- **Implementers are dispatched by reference.** The dispatch names the plan path, task heading and spec path; the implementer reads its task from the plan. Strict-tier dispatches still carry the task inline.
- **Reports go to files; returns are short.** Implementers and reviewers write the full report to a path the dispatch names and return at most 15 lines. With no path given, or when the harness refuses the write (it refuses generic names such as `report.md`, so the workspace uses specific ones), the full report comes back inline.
- **Handoff files live in `.fablepowers/<plan>/`.** A per-plan workspace at the worktree's top level holds reports, review packages and the ledger. It ignores itself, leaves a repo's own `.fablepowers/.gitignore` alone, and is safe to delete after merge. Work with no plan keys it on the spec file, or on `@<branch-name>` when there is no spec either (`/` becomes `-`; names starting with `.` and `@` plus an existing `.md` file are refused).
- **A progress ledger makes resume safe.** The orchestrator appends one line per checked task, and one per integration review and fix round, to `progress.md`; after compaction or in a new session it reconciles the ledger with `git log`, never re-dispatches a committed task, runs the pending checks of a commit that has no ledger line yet, and counts re-reviews against the cap, so the fix after the second re-review goes to `fablepowers:verify-done`, not a third review. The workflow map points a resumed session to `fablepowers:subagent-execution`, since compaction re-injects only the map.
- **Integration review diffs from the merge-base.** A new `review-package` script writes the commit list, `--stat` and diff from `git merge-base <base> HEAD`, so base-side commits no longer show up as phantom deletions. Empty ranges and unrelated histories exit 3.
- **The orchestrator doesn't coach reviewers.** Dispatches never carry a pre-rated severity, an instruction to ignore something, or the implementer's rationale; a stated rationale never lowers a finding's severity, and a defect the plan mandates is still reported, flagged plan-mandated.
- **Reviewers list what they declined to judge, and the orchestrator rules on each.** The final report to the user gains a phone-readable **Rulings I made** section: declined-to-judge items, capped re-review leftovers, plan conflicts resolved, plan-mandated defects kept.
- **Reviewers judge spec silence by what a reasonable user would expect**, and never run `checkout`, `reset`, `stash` or similar in the shared tree; other revisions go in a throwaway worktree.
- **Plans carry a Review Focus section**: up to five spec-implied inputs no task tests yet, each assigned to the owning task; plan review checks it.
- **Design asks who owns the how.** `design-spec` asks which platform, language and library choices the user wants to make; defaults go under "Decisions I made".
- **Substantial specs get a builder check.** A fresh reviewer reads the spec as its builder and lists what it would have to guess; the build-changing questions reach the user in one round before the approval brief.
- **`behavioral-testing` names three more anti-patterns:** mirror assertions, change detectors, and the string-presence trap.
- **The SessionStart hook works with a broken `PATH` wherever bash is at `$BASH` or a standard absolute location.** The `hooks.json` command picks bash with sh builtins only — `$BASH`, then `/bin/bash`, `/usr/bin/bash`, `/usr/local/bin/bash`, `/opt/homebrew/bin/bash`, and a PATH lookup only if none exists — and the script uses only bash builtins; 0.2.x failed with `env: 'bash': No such file`. Output is unchanged. Tested through `/bin/sh -c` and `/bin/bash -c`, and through a non-bash sh with `BASH` unset (dash where installed, otherwise zsh in sh emulation), each under a normal and an empty `PATH`. The hook and `review-package` each ship a test suite.

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
