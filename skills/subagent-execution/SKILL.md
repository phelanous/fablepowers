---
name: subagent-execution
description: Use when executing an implementation plan with subagents - the orchestrator never implements a plan task; dispatch a named, pinned-model agent per task.
---

# Subagent Execution

Execute a plan by dispatching a fresh subagent per task. Context isolation is the point: implementers get exactly the context they need, never your session history, and your context stays free for coordination.

## Who implements

**The orchestrator never implements a plan task.** Not when the task is small, not when you already have the files open, not when dispatching feels slower. The only code you write yourself is a one-line fix inside the review loop — and when you do it, say so in your report to the user.

| Seat | Agent | Tier | Does |
|---|---|---|---|
| Orchestrator | the user's session | whatever the session runs | design dialogue, plan, dispatch, spot-check, fix-loop decisions, user communication. **Never implements a plan task.** |
| Implementer | `fablepowers:implementer` | frontier | one plan task per dispatch, fresh context, behavioral tests with the mutation check, commit, report |
| Strict implementer | `fablepowers:strict-implementer` | mid | mechanical, fully specified tasks under the imperative red-green prompt; followed by a spec-check |
| Reviewer | `fablepowers:reviewer` | frontier | plan review, integration review, spec-check, builder check of a substantial spec; fresh context; never an agent that implemented anything in the feature |

Skills are invoked by name as `fablepowers:<skill>`; each seat is dispatched as its named agent, `fablepowers:<agent>`, never a generic agent that inherits your model. The harness reference (`fablepowers:workflow`'s `references/<harness>.md`) maps these actions to your harness's tools and each seat to its model. A plan header or task names its seat as `implementer` or `strict-implementer`; older plans say `opus` and `sonnet-strict`, which mean the same seats.

**`implementer` flow (the default):**
1. Plan was already reviewed (`fablepowers:implementation-plan`). Dispatch one `fablepowers:implementer` per task, by reference (see Dispatch hygiene).
2. The implementer implements, satisfies the task's test obligations including the mutation check (`fablepowers:behavioral-testing`), runs the suite, commits, self-reviews, writes its report to the path you named and returns the short form.
3. You spot-check the short return and the diff — no reviewer subagent per task. Open the full report when the short return is ambiguous, lists deviations you need to weigh, or a fix needs dispatching. Then append the ledger line.
4. After all tasks: **`fablepowers:integration-review`** (rigid gate).

**`strict-implementer` flow (mechanical, fully specified tasks):**
1. Dispatch `fablepowers:strict-implementer` with `prompts/implementer-strict.md` — imperative, code-level task detail, strict TDD ordering, the task text inline (that detail lives nowhere else). The rails exist because these models skip steps and rationalize; keep them.
2. After each task: dispatch a `fablepowers:reviewer` with `prompts/spec-check.md` (fresh context, verifies the diff point-by-point against the task spec). Loop implementer fixes until compliant, then append the ledger line.
3. After all tasks: **`fablepowers:integration-review`** as usual.

## Workspace and ledger

Handoff files live in a per-plan workspace, `<toplevel>/.fablepowers/<plan-basename-without-.md>/`, where `<toplevel>` is `git rev-parse --show-toplevel` of the worktree doing the work. Create it before the first dispatch:

```bash
bash "<this skill's base dir>/../integration-review/review-package" --init <plan-file>
```

It prints the workspace path and writes `<toplevel>/.fablepowers/.gitignore` (containing `*`) only if absent, so the files stay out of `git status`. Two plans with the same basename in different directories share a workspace — a known limitation; rename one if both are in flight. A spec and its plan usually share a basename, and so a workspace (the ledger header names whichever ran `--init` first); that is harmless, since their report names differ.

**Report paths** (inside the workspace), named in every dispatch: implementer `reports/task-<n>.md`, fix rounds `reports/task-<n>-fix<k>.md`; spec-check `reports/spec-check-task-<n>.md`; fixes for integration-review findings `reports/integration-fix<k>.md`. The review report paths are in the skills that dispatch them: plan review in `fablepowers:implementation-plan`, builder check in `fablepowers:design-spec`, integration review and re-reviews in `fablepowers:integration-review`.

**Ledger** — `<workspace>/progress.md`, written only by you. `--init` writes line 1, `# Progress: <plan path>`, if the file is absent. Then one line per completed task, appended once its checks pass (your spot-check, or a COMPLIANT spec-check on the strict tier), and one line per integration-review round and fix round as each comes back (see `fablepowers:integration-review`):

```
task <n> | <sha7> | <status> | <report path>
review integration | <head7> | <verdict> | reports/review-integration.md
fix integration-<k> | <sha7> | <status> | reports/integration-fix<k>.md
review rereview-<k> | <head7> | <verdict> | reports/review-rereview-<k>.md
```

**On resume** — after compaction, in a new session, or whenever you're unsure what has run — read `progress.md` and `git log` before dispatching anything.

- A task with a ledger line is done: do not re-dispatch it.
- A commit without a ledger line means the task's checks are pending, not that it is done. Don't re-dispatch the implementer; read its report, run the checks it is owed — your spot-check, or the spec-check on the strict tier, with any fix loop that follows — and add the line only when they pass.
- Review lines tell you where the review loop stands: the last `review` line is the latest round and the number of `review rereview-` lines is what the cap of two has used. A `fix` line with no `review` line after it is owed its re-review — unless two `review rereview-` lines precede it: then the cap is reached, that fix was the capped one, and what it is owed is `fablepowers:verify-done`, not a review.
- A fix commit in `git log` with no `fix` line (compaction while the fixer was in flight) is treated like a task commit without a line: don't re-dispatch the fix; read `reports/integration-fix<k>.md`, add its `fix` line, then do what that line is owed under the rule above (re-review, or verify-done once capped).
- A one-liner fix you made yourself (the only code you write) gets a ledger line like any fix, with `—` as the report and its commit SHA: `fix integration-<k> | <sha7> | DONE | —`.
- If the ledger names a SHA that `git log` doesn't have, the ledger is wrong — trust the log and ask the user if the gap is unclear.

## Dispatch hygiene (both flows)

- **Always dispatch the named seat**: the `fablepowers:implementer` agent (or `strict-implementer`, `reviewer`), named explicitly in the dispatch. Never a generic agent that inherits your model: it runs on your model and effort — dispatching it is not a delegation, it is your own session in a second window.
- **Dispatch by reference.** An implementer dispatch names the plan path (absolute, and readable from the implementer's working directory — check it is there when the worktree was created after planning), the task's heading and the spec path; the implementer reads its task, contracts, invariants and test obligations from the plan. The prompt carries only what the plan doesn't: how to run the tests, the commit convention, fix-round findings (or the path to the review report holding them), and the report path. Strict-tier dispatches keep their code-level prompt with the task text inline.
- **Short returns.** Every dispatch names its report path. Use the workspace names above, never a generic `report.md`, `summary.md`, `findings.md` or `analysis.md` — a harness may refuse subagent writes to those basenames (any directory, any case; see the harness reference), and an agent whose write is refused returns its full report inline instead. Implementers return at most 15 lines — `Status`, `SHA`, `Tests` (one line), `Deviations: <count>` plus up to 3 one-line headlines, `Report: <path>`; reviewers return `Verdict`, one line per must-fix (`file:line — headline`), `Declined to judge: <count>`, `Report: <path>`. Keep the full reports in their files; pass a path to the next agent rather than pasting a report into its prompt.
- **No coaching reviewers** — spec-checks included. A reviewer dispatch carries the task or spec, the range, the paths and how to run things; never a pre-rated severity, an instruction to ignore or go easy on something, or the implementer's rationale for a choice. A defect the plan itself mandates is still reported, flagged plan-mandated; take it to the user.
- **Fix-round dispatches carry test obligations.** When an implementer is sent to fix review findings, pass the review report's path and list each must-fix finding's failure scenario as a test obligation — fails on the current code, passes after the fix — and expect before/after evidence per finding in the report (`reports/task-<n>-fix<k>.md`; for integration-review findings, `reports/integration-fix<k>.md`). The full rule is in `fablepowers:integration-review`.
- Implementers may ask questions before starting — answer, then re-dispatch.
- One task in flight per dependency chain; independent tasks may run in parallel.
- Track tasks in your harness's task list; mark complete only after the task's checks pass — the same moment the ledger line goes in.

## Failure handling

If an implementer's report claims success but the diff or test output says otherwise, re-dispatch that task with the strict prompt to a `fablepowers:strict-implementer`, or dispatch a fresh `fablepowers:implementer` with the failure attached. Taking the task yourself is not one of the options.

## Why

The first fork-era audit measured where the work actually happened: the orchestrator's model produced 97% of all output tokens — 78% in the main loop itself, the rest in subagents that inherited its model because no model was set on the spawn. 9 of 13 plan documents recorded "orchestrator implements directly". Only 4 of 12 sessions that wrote a plan dispatched implementers at all. The wording that allowed it is gone; the agents above exist so the model choice lives in a definition file rather than in whatever prompt gets typed at dispatch time. See `docs/rationale.md`.
