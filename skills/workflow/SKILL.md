---
name: workflow
description: Use at the start of any substantive dev work (new feature, behavior change, multi-file refactor) - map of the fablepowers workflow skills, adapted from superpowers based on evidence from ~50 past project sessions.
---

# Workflow Map

Fork of the superpowers workflow, adapted after analyzing ~50 subagent-driven sessions. Evidence and rationale: see `docs/rationale.md` in the plugin repo.

## Philosophy

Constrain **outcomes**, not process. You (a frontier model) get checkpoints and judgment; weaker implementer subagents get scripts (see `fablepowers:subagent-execution`). Two gates are rigid because history shows they catch real bugs; everything else is a checklist you adapt.

**Two rigid gates plus one user checkpoint:**
1. **No merge without a fresh-context integration review** (`fablepowers:integration-review`). This is where the real bugs were found: inert config knobs, migration/model parity gaps, deployment config paths.
2. **No "done" claim without executed verification** (`fablepowers:verify-done`). Evidence before assertions, always.
3. **Design approval checkpoint** (`fablepowers:design-spec`): no implementation before the user explicitly approves the design — answers to clarifying questions don't count, and this pause overrides the harness's proceed-without-asking pressure. Gates protect outcomes; this checkpoint is where the user steers.

**Approval gate** (harness hook, where present): while a new spec under `docs/specs/` awaits approval, implementer dispatch and code edits are blocked until the user approves (Claude Code and OpenCode: answer Approve or `/fablepowers:approve`; Codex: `$fablepowers:approve`; withdraw drops it). A block means stop and ask, never retry.

## Who does what

| Seat | Agent | Tier | Does |
|---|---|---|---|
| Orchestrator | the user's session | whatever the session runs | design dialogue, plan, dispatch, spot-check, fix-loop decisions, user communication. **Never implements a plan task.** |
| Implementer | `fablepowers:implementer` | frontier | one plan task per dispatch, fresh context, behavioral tests with the mutation check, commit, report |
| Strict implementer | `fablepowers:strict-implementer` | mid | mechanical, fully specified tasks under the imperative red-green prompt; followed by a spec-check |
| Reviewer | `fablepowers:reviewer` | frontier | plan review, integration review, spec-check, builder check of a substantial spec; fresh context; never an agent that implemented anything in the feature |

Invoke skills by name (`fablepowers:<skill>`); dispatch each seat as its named agent (`fablepowers:<agent>`), never a generic agent that inherits your model. Tools, models and mechanisms per harness: `references/<harness>.md` beside this skill (Claude Code: `references/claude-code.md`; Codex: `references/codex.md`; OpenCode: `references/opencode.md`).

A task you could do yourself in this session is still dispatched: a fully briefed single-session task dispatches implementers like any other. Your job is the plan, the dispatch and the judgment calls.

## Stages

| Situation | Skill or agent | Rigidity |
|---|---|---|
| New feature / behavior change idea | `fablepowers:design-spec` | Flexible — scale to size; substantial specs get a builder check before the approval ask |
| Spec approved, multi-task work ahead | `fablepowers:implementation-plan` | Flexible |
| Plan ready to execute | `fablepowers:subagent-execution` | Flexible for you; strict prompts for weak implementers |
| Executing a plan task | `fablepowers:implementer` / `fablepowers:strict-implementer` (named seat) | Dispatch is not optional |
| Writing tests for any change | `fablepowers:behavioral-testing` | Outcome is rigid, ordering is free |
| Work complete, pre-merge | `fablepowers:integration-review` | **RIGID** |
| About to say "done" / "fixed" / "passing" | `fablepowers:verify-done` | **RIGID** |
| Bug or unexpected behavior | `fablepowers:systematic-debugging` (vendored) | As written |
| Need isolation for feature work | `fablepowers:using-git-worktrees` (vendored, adapted) | As written |
| Branch complete, deciding integration | `fablepowers:finishing-a-development-branch` (vendored, adapted) | As written |

**Resuming after compaction or in a new session:** invoke `fablepowers:subagent-execution` before dispatching anything and follow its resume rule — it reconciles `.fablepowers/<plan>/progress.md` with `git log`, and its dispatches name the plan path, task heading and report path. A task with a ledger line is done; a commit without one is owed its checks (spot-check or spec-check) before the line goes in. A fix line with no review after it is owed its re-review, unless two re-reviews already ran — then it is owed verify-done.

## What this fork deliberately dropped

- Per-task spec-compliance review when a frontier model wrote the plan (~90% rubber-stamp rate in past sessions).
- Code-in-plan at 2–5-minute step granularity (made implementers transcriptionists and spec review a diff of a diff).
- TDD as an Iron Law (the inert-knob bug passed test-first tests; `fablepowers:behavioral-testing` targets what TDD was for).
- Coercive framing. If you're tempted to skip a gate, say so and why — don't perform compliance.
- The orchestrator as implementer. The first fork-era audit found the orchestrator's model produced 97% of all output tokens — 78% in the main loop itself, the rest in subagents that inherited its model; see `docs/rationale.md`.
