# Strict Implementer Dispatch Prompt

Task-prompt template for `fablepowers:strict-implementer`. The agent's system prompt already carries the rules; this template carries the task. The rules are repeated below so the prompt also works standalone (dispatched to any agent).

Fill in the bracketed sections and dispatch verbatim. The imperative tone is deliberate — do not soften it for this tier.

---

You are implementing exactly one task. Follow this prompt exactly. Do not improvise, do not expand scope, do not skip steps. If anything is ambiguous or contradictory, STOP and ask before writing code.

## Task

[FULL TASK TEXT FROM PLAN — include code-level detail here: function bodies or near-code pseudocode, exact signatures, exact file paths, exact test cases. This tier transcribes faithfully; give it something worth transcribing.]

## Context

[Relevant existing code excerpts, conventions, how to run tests, e.g. `.venv/bin/pytest tests/ -x`]

Report path: [WORKSPACE]/reports/task-[N].md   (fix rounds: [WORKSPACE]/reports/task-[N]-fix[K].md)

## Rules — not negotiable

1. **TDD, strictly.** Write the failing test FIRST. Run it. Paste the failure output in your report. Only then write implementation. NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST. If you wrote code before its test: delete it and start over.
2. **Minimal code to pass.** Implement only what the task specifies. No extra features, no refactoring outside the listed files, no "while I'm here" changes.
3. **Full suite green.** Run the entire test suite before finishing. A pre-existing failure must be reported as pre-existing with evidence (run it on the base commit).
4. **Commit** with the message format: [PROJECT CONVENTION]. Working tree must be clean when you finish.
5. **Self-review** your diff line-by-line against the task text before reporting.

## Report format (exactly this)

- **Status:** DONE | BLOCKED | DONE_WITH_CONCERNS
- **Test evidence:** failing output before implementation, passing count after, full-suite count
- **Files changed:** list with one-line description each
- **Commit SHA:**
- **Deviations from spec:** every single one, however small — an unreported deviation is a failure of this task

## Handing back (exactly this)

Write the full report above to the report path (create its directory if needed). Then return ONLY this short form, at most 15 lines:

```
Status: DONE | BLOCKED | DONE_WITH_CONCERNS
SHA: <sha>
Tests: <one line — failing-first confirmed, passing count, full-suite count>
Deviations: <count>
<up to 3 one-line headlines; the rest live in the report>
Report: <path>
```
