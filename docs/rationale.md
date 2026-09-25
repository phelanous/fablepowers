# Why fablepowers looks like this

Every rule in this plugin exists because session logs said it should. This
document is the evidence: what the superpowers workflow cost and caught across
~1,470 Claude Code sessions, what changed when it was forked, and what the
first fork-era audit found still broken.

Three measurement rounds are recorded here. The baseline (2026-07-20) is frozen —
the logs behind it have since been purged. The fork-era check-in (2026-09-07)
covers the 27 sessions from 2026-08-01 onward and is reproducible; the second
check-in (2026-09-24) covers the 40 sessions on the 0.1.0 plugin.

## Reproduce

```bash
python3 scripts/analyze_delegation.py                      # all sessions
python3 scripts/analyze_delegation.py --since 2026-08-01   # the fork-era window
```

The script reads `~/.claude/projects`, pairs each session transcript with its
own subagent transcripts, and prints per-session main-loop vs subagent tokens,
who edited files, which model each subagent actually ran on, and whether the
design-approval checkpoint got a user turn. See "Measuring it" in the README
for the columns.

## Baseline numbers (2026-07-20, superpowers era)

- 1,467 session files; 49 sessions used `superpowers:subagent-driven-development` (SDD), across six projects — a trading-scanner web app, a Flutter + FastAPI medication app, two self-hosted services, an infrastructure agent, and a notes repo.
- Skill usage: writing-plans 64, brainstorming 63, SDD 54, finishing-a-development-branch 54, TDD 22, systematic-debugging 20.
- **Tokens:** all sessions output = 51.9M; SDD subset output = 29.1M → **SDD sessions were 3% of files but 56% of all output tokens** (~595k output tokens per SDD session). Cache-creation in SDD subset: 188M tokens — the tax of cold-start subagent fan-out (every spawn re-reads plan + code).
- **Agent spawns in SDD sessions:** ~1,249 reviewer-role vs 93 implementer-role (heuristic on dispatch prompts). Roughly 3+ agents paid per landed task (implementer, spec reviewer, quality reviewer, re-review loops).
- Main-loop drivers: frontier models. Implementer/reviewer subagents frequently Sonnet-class.
- Review verdict classification by regex is noisy (most results are long prose); manual sampling put actionable-fix rate at roughly 10–25% of review passes, with per-task **spec** reviews overwhelmingly returning "byte-for-byte match to the plan."

## Qualitative findings

**Where reviews earned their cost** — fresh-context review of the *integrated*
feature, not per-task spec fidelity:

- An **inert config knob** in the trading-scanner app (`confirmation_step` changed nothing; its TDD-written test asserted grid *structure*, not behavior).
- A **migration ⇄ model parity gap** in the medication app (tests used `create_all`, which rendered a CASCADE the migration lacked).
- A Dockerfile / migration-config path in the same app that only worked by accident; status-engine correctness issues.
- Common thread: bugs live at **integration seams** — knobs, migrations vs models, deployment config, cross-component contracts.

**Why per-task spec review rubber-stamped:** `writing-plans` mandated
2–5-minute steps with actual code in the plan. A frontier-model plan therefore
*was* the implementation; implementers transcribed, and spec reviewers verified
transcription.

**TDD for agents:** ritual compliance was common (RED via `ModuleNotFoundError`,
delete-and-restart rules) and the flagship bug (inert knob) passed *through*
test-first tests. When one mind writes plan, test, and code in a single intent,
test-first ordering doesn't buy independence — a proven-to-fail check does.
Exception: for **bug fixes**, the failing test is the reproduction and ordering
genuinely matters.

**Friction:** zero in-session user pushback across the whole corpus; the cost of
the coercive skill framing showed up as token overhead and performative
compliance, not arguments.

## Decisions (2026-07-20): the fork

| Skill | Replaces | Change |
|---|---|---|
| `workflow` | using-superpowers | Map + philosophy; no "1% rule" |
| `design-spec` | brainstorming | Same dialogue, tiered by size, no HARD-GATE theater |
| `implementation-plan` | writing-plans | Interface-level (contracts/invariants/test obligations), PR-sized tasks, adds up-front plan review; **no code-in-plan** |
| `subagent-execution` | subagent-driven-development | Fresh implementer per task kept; per-task spec review only for strict-tier (Sonnet/Haiku) implementers via `prompts/implementer-strict.md` + `prompts/spec-check.md` |
| `behavioral-testing` | test-driven-development | Rigid outcome (every spec behavior has a test *proven* to fail when broken — mutation check), free ordering for frontier models, strict TDD retained for weak subagents |
| `integration-review` | requesting-code-review | **RIGID gate** — fresh-context adversarial reviewer, must execute, seam-focused checklist |
| `verify-done` | verification-before-completion | **RIGID gate** — condensed, unchanged in spirit |

Kept from superpowers as-is: systematic-debugging, using-git-worktrees,
finishing-a-development-branch.

Core principle: **constrain outcomes, not process; make strictness
model-conditional.** The orchestrator gets checkpoints; weak implementer
subagents get the original imperative rails, which the logs show working for
them.

**Amendment 2026-07-31:** the first fork-era sessions ran fast but rolled
through design interaction — clarifying questions collapsed to one batched
round, and the spec-approval step never fired (a new-feature session wrote the
spec and invoked implementation-plan in the same turn, treating question-answers
as approval). Root cause: soft checklist steps lose to the harness's
proceed-without-asking autonomy pressure; superpowers' HARD-GATE had been doing
that load-bearing work. Fix, without restoring blanket coercion: `design-spec`
now requires questions in rounds (batching only for cosmetic choices), a tier
rule (user-visible behavior is never trivial; new feature = substantial by
default), and a **blocking approval checkpoint** — explicit user yes on the
assembled design, named as input only the user can provide so the autonomy
directive doesn't override it. `workflow` now says "two rigid gates plus one
user checkpoint." Lesson: when stripping coercion from agent workflows,
interactive checkpoints must be explicitly marked as *user decisions* or
momentum erases them.

## What to watch after switching

1. Output tokens per subagent-execution session vs ~595k baseline.
2. Reviewer-spawn : implementer-spawn ratio (baseline ~13:1 by heuristic; expect ~1–2:1 for frontier-tier work).
3. **Escaped bugs**: bugs found in a *later* session touching the same code — the number that must not rise.
4. Whether integration reviews keep finding seam bugs (if they go quiet, either quality rose or the reviewer prompt dulled — check which).

## Fork-era check-in (2026-09-07)

Re-run on the 27 sessions dated 2026-08-01 → 2026-09-07 (older logs have been
purged; the baseline numbers above are frozen). (Snapshot as of 2026-09-07;
re-run the script for current numbers.) New harness:
`scripts/analyze_delegation.py` — pairs each main transcript with its
`<session>/subagents/agent-*.jsonl` files, which a naive counter wrongly treats
as sessions.

### What is working

- Adoption is complete: `workflow` in 21/27 sessions; superpowers brainstorming/writing-plans/SDD have not been invoked since 2026-07-19.
- The 07-31 approval checkpoint fired in 17 of 19 `design-spec` sessions — an explicit "approve?" ask, then a user "approved" turn. Two misses: approval bundled into the same `AskUserQuestion` as design choices, and a "which design?" answer treated as approval. A softer pattern in 4 more sessions: the approval question shares an `AskUserQuestion` with still-open design questions.
- `integration-review` earns its cost: 55 dispatches, every one executes (16–82 Bash calls per review), and ~10 of 18 first-pass reviews found a blocker/must-fix (a dropped rerun in an outbox, a missing undo compensation, dead fallback caching, etc.). Re-review loops run long in places (one feature went 6 rounds).

### What is not: delegation collapsed into the main loop

- The orchestrator model produced **97%** of all fork-era output tokens (main loop 11.5M, subagents 3.2M → subagent share 22%).
- The subagents *were* the orchestrator: `model` was unset on 101 of 114 `Agent` spawns (inherits the orchestrator's model, at inherited `xhigh` effort). Only one session passed `model: opus` — and it ran cleanly: 13 Opus subagents, 3 main-loop edits, 2.1 h wall, a real blocker caught by the Opus reviewer.
- Implementation moved in-session: main loop 592 Edit/Write + 368 Bash file-writes vs 288 subagent edits. `subagent-execution` was invoked in 4 of 21 workflow sessions; 8 of 12 sessions that wrote a plan then implemented it themselves. Plan headers say it outright: 9 of 13 plans read "Implementer tier: frontier (orchestrator implements directly; no dispatch prompts)".
- **Root cause is skill wording.** `subagent-execution` defined the tier as "Frontier implementers (Fable/Opus/main-loop quality)" and `implementation-plan` offered "Implementer tier: frontier | strict". The orchestrator reads "frontier" as itself. No skill named who implements or which model reviewers run on, so both defaulted to the orchestrator.
- Cost (estimated from usage records at 2026-06 list prices; the top-tier cache-read rate is assumed): ~$2,780 for 27 sessions — main loop $1,860, subagents $920. Inside the main loop, cache writes+reads ($1,280) exceed output ($574): the growing in-session context is the largest line item, and in-session implementation is what grows it. Per workflow session: mean 675k output tokens (523k main + 152k sub) vs the ~595k SDD baseline — cost did not fall, it moved from Sonnet subagents to the orchestrator's main loop.

### Decisions (2026-09-07): this plugin

- Implementer and reviewer become **named agents with pinned models** (`fablepowers:implementer` on Opus, `fablepowers:strict-implementer` on Sonnet, `fablepowers:reviewer` on Opus). The model choice lives in a definition file instead of in whatever prompt the orchestrator happens to write.
- **The orchestrator never implements a plan task.** The only code it writes itself is a one-line fix inside a review loop, and it says so when it does.
- `implementation-plan` drops the "frontier" tier label; the header field names an agent, not a tier.
- `design-spec` requires the **approval ask to stand alone** — its own single-question call or its own message, never sharing a call with an open design question.
- Integration re-review rounds are **capped at two**, after which remaining must-fix items are fixed, `fablepowers:verify-done` runs, and the report says the loop was capped.
- The fork ships as this plugin, with a SessionStart hook that loads the workflow map so no per-machine configuration is needed.

The numbers to re-run against after this change are the same four in "What to
watch", plus the two the audit added: subagent share of output tokens (was 22%)
and the count of `Agent` spawns with `model` unset (was 101 of 114).

## Second check-in (2026-09-24)

Re-run on the 40 sessions dated 2026-09-08 → 2026-09-24, all on the 0.1.0
plugin. (Snapshot as of 2026-09-24; re-run the script for current numbers.)

### What is working: delegation

- Subagent share of output tokens rose to **59%** (was 22%).
- Implementation left the main loop: 185 main-loop Edit/Write plus 357 Bash file-writes vs 2,028 subagent edits (was 960 vs 288).
- Reviewer:implementer spawns are 127:254 = **0.5:1** (was 2.4:1). Implementers now outnumber reviewers. Counting method: the 127:254 counts Agent spawns by `subagent_type` (`fablepowers:reviewer` vs `fablepowers:implementer` + `fablepowers:strict-implementer`). The 0.1.0 baseline (~13:1) and the August 2.4:1 were classified by the script's prompt-text heuristic, which puts reviewers ahead because fix-round dispatches mention "review"; the script now uses `subagent_type` for fablepowers agents and the heuristic for everything else.
- 91% of subagent output ran on Opus — the pinned-model agents are what actually runs.
- Cost (estimated from usage records, same pricing basis as above): main loop $1,638, subagents $3,475. Spend moved to where the work is done.

### What is not: approval asks without a design

- 16 of 42 approval asks fired with no design summary in the same turn.
- Every thin ask has the same shape: the design variants moved into the `AskUserQuestion` options ("Approve, skip the themed test") and the summary was dropped. The 0.1.0 wording "the ask stands alone" was read as "the ask must be alone".
- Approvals are often reviewed on a phone through remote control, where the spec file may not open. An ask that points at the file without summarizing it asks for a yes the user cannot inform.

### Review yield

Regex classification, approximate:

- Plan reviews carry a must-fix ~50% of the time.
- Integration reviews ~35%.
- Scoped re-reviews ~40%; "final" re-reviews ~40%.
- Re-review must-fixes are often regressions introduced by the fix commit itself.

### Decisions (2026-09-24)

`fablepowers:design-spec` now ends in a **design brief** followed by the ask,
in the same turn: six fixed headings (What changes, Decisions I made, Not doing,
Risk, Open the spec if, Verified by), at most 20 words per bullet, no tables,
written to be judged from a phone; the spec file is the appendix. The ask is one
question with exactly two options, Approve and Changes needed — a design variant
is a design question and is asked in an earlier round. When an implementer is
dispatched to fix review findings, `fablepowers:subagent-execution` and
`fablepowers:integration-review` now require each must-fix finding's failure
scenario to arrive as a **test obligation**: a test that fails on the current
code for that scenario and passes after the fix, with before/after evidence per
finding in the report — aimed at the regressions re-reviews keep finding in fix
commits. Review cadence and the two-round re-review cap are unchanged: the
yields above say the reviews earn their cost.
