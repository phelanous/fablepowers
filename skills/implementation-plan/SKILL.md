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
- **Depends on:** exactly one `**Depends on:** …` line (see Dependencies and waves)
- **Touches:** exactly one `**Touches:** …` line (see Parallel safety section)

**Do not include** full function bodies or verbatim code blocks — in any task. Code-level detail belongs only in the **dispatch prompt** of a `strict-implementer` task (see `fablepowers:subagent-execution`), never in the plan document.

## Task granularity

One task = one coherent, independently-testable, committable change (roughly one focused PR-commit). Not 2–5-minute micro-steps.

## Task headings

Keep the plan's own heading style; the wave script accepts three: `## T<id>: <title>`, `## Task <id> — <title>` (em dash, en dash, hyphen or colon), and `### Task <id> <title>`. `<id>` is digits optionally followed by letters (`3`, `7b`). `T3`, `Task 3` and `3` name the same task, and ids compare case-insensitively. A heading starts in column 0; headings inside code fences or indented under a list don't count. The same goes for a task's `**Depends on:**` and `**Touches:**` lines: each starts in column 0, because the wave script ignores an indented or bulleted one, and a task whose Depends on line it ignored is reported as `no-depends`.

## Dependencies and waves

Tasks with no dependency between them run in parallel, each in its own worktree, so the dependency lines decide how much of the plan runs at once. Every task has exactly one `**Depends on:**` line, starting in column 0 anywhere in its body before the next task heading. It holds `nothing` (or `none`, any case), or a comma-separated list of ids, each optionally followed by a parenthesised reason with no parentheses inside: `**Depends on:** T1 (enum types), T3`.

Task B depends on task A only when B needs A's code to exist: it calls it, imports it, extends it, or migrates on top of it. When B needs only a type, schema, enum or API shape from A, that is not a dependency: pin the contract in the plan's shared section and have both tasks build against it. Test-infrastructure ordering is not a dependency either; it belongs in Parallel safety. A dependency that a shared contract could replace costs a whole wave of waiting.

**Sequence numbers** that two tasks could both claim (migration numbers, error codes, fixture ports and the like) are assigned in the plan, never left to the implementers.

## File structure section

Before tasks, map the files involved and their responsibilities — this locks in decomposition. Prefer small focused files; follow existing codebase patterns.

## Parallel safety section

After File structure, a `## Parallel safety` section: one line per shared resource that tasks may contend for, in the form `<name> — isolate: <how>` or `<name> — serialize`. Typical resources are test databases and their ports, dev-server ports, browser e2e runs, generated files, and a file two independent tasks both edit. `isolate` names the mechanism and who assigns the instance, for example "test DB per worktree; the orchestrator assigns port 55440+n via `LEDGERLINE_TEST_DATABASE_URL`". The body `None.` means you looked and found none.

A `serialize` line is one of two kinds, and its name says which. A **file-contention** resource is only a file that two tasks edit: name it by the file's repository path, as in `agents/implementer.md — serialize (T4 and T5 both edit it)`. Every other `serialize` resource — a test database, a port, a browser e2e run, a CLI login — is a **run** resource, one that running the tests uses, so give it a name that isn't a path, such as `e2e — serialize`. The post-merge check run and a check fix hold every run resource and no file-contention resource, so a task on a resource named by a path never waits for a check, and a task on any other `serialize` resource always does.

The section always includes a `worktree env` line, because a fresh task worktree holds only tracked files: no installed dependencies, `.env` or local config. Write `worktree env — isolate: <setup step or shared path>` (for example "`npm ci` in each worktree" or "symlink `.venv` from the plan worktree"), or `worktree env — none needed` when the suite runs on tracked files alone.

Every task has exactly one `**Touches:**` line, starting in column 0, naming resources from this section, or `none`. Tasks that share a `serialize` resource never run at the same time.

## Review Focus section

After the tasks, a **Review Focus** section: up to five inputs or failure modes the spec implies but no task's test obligations exercise — empty input, a concurrent call, missing config, a path outside the repo — most likely to bite a user first, one line each naming the condition and what a reasonable user would expect. The spec says what the software must do, not everything it will meet; its silence on an input is not permission for that input to break the program. Each line is then added as a test obligation to the task that owns the code, so it gets built and mutation-checked like any other. An empty section means you looked and found none, not that you skipped looking.

## Plan review (cheap, catches design bugs early)

Before executing, dispatch **one `fablepowers:reviewer`** (fresh context) to review the plan against the spec: contradictions, missing behaviors, contract mismatches between tasks, test obligations that don't actually pin the spec's behaviors, and whether the Review Focus section holds the spec-implied inputs most likely to bite — each assigned to an owning task. The reviewer also makes four parallel-execution checks, each failure a finding:

1. Every task has exactly one Depends on line and one Touches line.
2. No dependency that a shared contract could replace: a task that needs only another task's type, schema, enum or API shape should depend on a pinned contract, not on that task.
3. The Parallel safety section covers the resources the tasks touch, including the `worktree env` line, and every Touches entry names a resource listed there.
4. The plan passes `plan-waves`: the reviewer runs `bash "<subagent-execution base dir>/plan-waves" <plan>` itself (from this skill's directory, `../subagent-execution/plan-waves`) and reports a non-zero exit as a finding, quoting its `plan-waves: <kind>: …` stderr lines.

Name the report path `<workspace>/reports/review-plan.md` in the dispatch (workspace: `<toplevel>/.fablepowers/<plan-basename-without-.md>/`, created by `bash "<implementation-plan base dir>/../integration-review/review-package" --init <plan>`). Fix findings, then proceed to `fablepowers:subagent-execution`. This replaces per-task spec review — do it once, up front, where it's cheap.

## Header

```markdown
# <Feature> Implementation Plan

**Spec:** docs/specs/<file>.md
**Goal:** one sentence
**Architecture:** 2–3 sentences
**Implementer:** implementer | strict-implementer (default for tasks; a task may override with "Implementer: strict-implementer"; older plans' `opus` / `sonnet-strict` mean the same seats)
**Max parallel:** 4 (optional; the default is 4)
```

**Max parallel** caps the implementer dispatches in flight at once: task implementers, merge fixes and check fixes all count; reviewers and spec-checks don't. Lower it when the machine or the shared resources can't take four.
