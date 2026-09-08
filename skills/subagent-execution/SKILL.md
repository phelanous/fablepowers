---
name: subagent-execution
description: Use when executing an implementation plan with subagents - the orchestrator never implements a plan task; dispatch a named, pinned-model agent per task.
---

# Subagent Execution

Execute a plan by dispatching a fresh subagent per task. Context isolation is the point: implementers get exactly the context they need, never your session history, and your context stays free for coordination.

## Who implements

**The orchestrator never implements a plan task.** Not when the task is small, not when you already have the files open, not when dispatching feels slower. The only code you write yourself is a one-line fix inside the review loop — and when you do it, say so in your report to the user.

| Role | Agent | Model | Does |
|---|---|---|---|
| Orchestrator | the user's session | whatever the session runs | design dialogue, plan, dispatch, spot-check, fix-loop decisions, user communication. **Never implements a plan task.** |
| Implementer | `fablepowers:implementer` | Opus | one plan task per dispatch, fresh context, behavioral tests with the mutation check, commit, report |
| Strict implementer | `fablepowers:strict-implementer` | Sonnet | mechanical, fully specified tasks under the imperative red-green prompt; followed by a spec-check |
| Reviewer | `fablepowers:reviewer` | Opus | plan review, integration review, spec-check; fresh context; never an agent that implemented anything in the feature |

**`implementer` flow (the default):**
1. Plan was already reviewed (`fablepowers:implementation-plan`). Dispatch one `fablepowers:implementer` per task with the task's plan section + relevant context.
2. The implementer implements, satisfies the task's test obligations including the mutation check (`fablepowers:behavioral-testing`), runs the suite, commits, self-reviews, reports.
3. You spot-check the report and diff — no reviewer subagent per task.
4. After all tasks: **`fablepowers:integration-review`** (rigid gate).

**`strict-implementer` flow (mechanical, fully specified tasks):**
1. Dispatch `fablepowers:strict-implementer` with `prompts/implementer-strict.md` — imperative, code-level task detail, strict TDD ordering. The rails exist because these models skip steps and rationalize; keep them.
2. After each task: dispatch a `fablepowers:reviewer` with `prompts/spec-check.md` (fresh context, verifies the diff point-by-point against the task spec). Loop implementer fixes until compliant.
3. After all tasks: **`fablepowers:integration-review`** as usual.

## Dispatch hygiene (both flows)

- **Always pass the agent type explicitly.** The default general-purpose agent inherits your model and effort — dispatching it is not a delegation, it is your own session in a second window.
- Include in the prompt: full task text, file paths, contracts, invariants, test obligations, how to run the tests, commit instructions.
- Implementers may ask questions before starting — answer, then re-dispatch.
- One task in flight per dependency chain; independent tasks may run in parallel.
- Track tasks in TodoWrite/TaskCreate; mark complete only after the task's checks pass.

## Failure handling

If an implementer's report claims success but the diff or test output says otherwise, re-dispatch that task with the strict prompt to a `fablepowers:strict-implementer`, or dispatch a fresh `fablepowers:implementer` with the failure attached. Taking the task yourself is not one of the options.

## Why

The first fork-era audit measured where the work actually happened: the orchestrator produced 97% of all output tokens, and 9 of 13 plan documents recorded "orchestrator implements directly". Only 4 of 12 sessions that wrote a plan dispatched implementers at all. The wording that allowed it is gone; the agents above exist so the model choice lives in a definition file rather than in whatever prompt gets typed at dispatch time. See `docs/rationale.md`.
