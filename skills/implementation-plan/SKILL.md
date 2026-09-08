---
name: implementation-plan
description: Use after a design spec is approved and before executing multi-task work - writes an interface-level plan (contracts, invariants, test obligations), not code-in-markdown.
---

# Implementation Plan

Turn an approved spec into an executable plan. The plan specifies **what must be true**, not the code itself.

**Save to:** `docs/plans/YYYY-MM-DD-<feature>.md` (or project convention). Run in a worktree for substantial work (`fablepowers:using-git-worktrees`).

## Altitude: interfaces, not code

Past-session evidence: code-level plans made implementers transcriptionists and turned spec review into a rubber stamp (~90% "byte-for-byte match"). Plan at the level a strong senior engineer briefs another:

**Each task specifies:**
- Files to create/modify and each file's single responsibility
- Public contracts: signatures, types, schemas, API shapes — exact where the seam matters, omitted where it doesn't
- Invariants and constraints the implementation must preserve (these are what reviews check)
- **Test obligations:** the observable behaviors that must have a test which fails when the behavior is broken (from the spec's "how we'll know it works")
- Dependencies on other tasks

**Do not include** full function bodies or verbatim code blocks — in any task. Code-level detail belongs only in the **dispatch prompt** of a `sonnet-strict` task (see `fablepowers:subagent-execution`), never in the plan document.

## Task granularity

One task = one coherent, independently-testable, committable change (roughly one focused PR-commit). Not 2–5-minute micro-steps.

## File structure section

Before tasks, map the files involved and their responsibilities — this locks in decomposition. Prefer small focused files; follow existing codebase patterns.

## Plan review (cheap, catches design bugs early)

Before executing, dispatch **one `fablepowers:reviewer`** (fresh context) to review the plan against the spec: contradictions, missing behaviors, contract mismatches between tasks, test obligations that don't actually pin the spec's behaviors. Fix findings, then proceed to `fablepowers:subagent-execution`. This replaces per-task spec review — do it once, up front, where it's cheap.

## Header

```markdown
# <Feature> Implementation Plan

**Spec:** docs/specs/<file>.md
**Goal:** one sentence
**Architecture:** 2–3 sentences
**Implementer:** opus | sonnet-strict (default for tasks; a task may override with "Implementer: sonnet-strict")
```
