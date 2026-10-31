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
3. You spot-check the short return and the diff — no reviewer subagent per task. Open the full report when the short return is ambiguous, lists deviations you need to weigh, or a fix needs dispatching. Then merge the task back and run its check (see Wave dispatch), and append the ledger lines.
4. After all tasks: **`fablepowers:integration-review`** (rigid gate).

**`strict-implementer` flow (mechanical, fully specified tasks):**
1. Dispatch `fablepowers:strict-implementer` with `prompts/implementer-strict.md` — imperative, code-level task detail, strict TDD ordering, the task text inline (that detail lives nowhere else). The rails exist because these models skip steps and rationalize; keep them.
2. After each task: dispatch a `fablepowers:reviewer` with `prompts/spec-check.md` (fresh context, verifies the diff point-by-point against the task spec). Loop implementer fixes until compliant, then merge the task back and run its check (see Wave dispatch), and append the ledger lines.
3. After all tasks: **`fablepowers:integration-review`** as usual.

## Workspace and ledger

Handoff files live in a per-plan workspace, `<toplevel>/.fablepowers/<plan-basename-without-.md>/`, where `<toplevel>` is `git rev-parse --show-toplevel` of the worktree doing the work. Create it before the first dispatch:

```bash
bash "<this skill's base dir>/../integration-review/review-package" --init <plan-file>
```

It prints the workspace path and writes `<toplevel>/.fablepowers/.gitignore` (containing `*`) only if absent, so the files stay out of `git status`. Two plans with the same basename in different directories share a workspace — a known limitation; rename one if both are in flight. A spec and its plan usually share a basename, and so a workspace (the ledger header names whichever ran `--init` first); that is harmless, since their report names differ.

The worktree doing the work is the plan branch's worktree (the plan worktree), where you run. Task worktrees (see Wave dispatch) never get a workspace of their own: every report, including one written from a task worktree, goes to the plan worktree's workspace by absolute path.

**Report paths** (inside the workspace), named in every dispatch: implementer `reports/task-<n>.md`, fix rounds `reports/task-<n>-fix<k>.md`; spec-check `reports/spec-check-task-<n>.md`; merge fixes `reports/task-<n>-merge<k>.md`; post-merge check fixes `reports/check-<n>-fix<k>.md`; fixes for integration-review findings `reports/integration-fix<k>.md`. `<n>` is the plan's task id without a leading `T` (`3`, `7b`), whichever heading style the plan uses: `reports/task-3.md`, ledger `task 3`, and lower-cased in branch and worktree names, `fp/<plan-key>/t3` and `<plan-key>-t7b`. `plan-waves` prints `T3` for a `## T3:` heading; drop the `T`, never write `task-T3.md` or `tt3`. Ids otherwise compare as written: `T01` and `T1` are different tasks. The review report paths are in the skills that dispatch them: plan review in `fablepowers:implementation-plan`, builder check in `fablepowers:design-spec`, integration review and re-reviews in `fablepowers:integration-review`.

**Ledger** — `<workspace>/progress.md`, written only by you. `--init` writes line 1, `# Progress: <plan path>`, if the file is absent. Then each task's fix, merge and check lines as they happen, one `task` line per completed task, and one line per integration-review round and fix round as each comes back (see `fablepowers:integration-review`):

```
fix <n>-<k> | <sha7> | <status> | reports/task-<n>-fix<k>.md
merge <n>-<k> | <sha7> | <status> | reports/task-<n>-merge<k>.md
check <n> | <head7> | PASS|FAIL | —
check <n>-fix<k> | <sha7> | <status> | reports/check-<n>-fix<k>.md
task <n> | <merge sha7> | <status> | <report path>
review integration | <head7> | <verdict> | reports/review-integration.md
fix integration-<k> | <sha7> | <status> | reports/integration-fix<k>.md
review rereview-<k> | <head7> | <verdict> | reports/review-rereview-<k>.md
```

A task's lines go in this order. First a `fix <n>-<k>` line as each fix round from your spot-check, or from a spec-check, returns; its SHA is the fix round's last commit on the task branch, or on the plan branch for a task run in place. Then a `merge <n>-<k>` line as each merge fix returns; its SHA is the merge-fix commit on the task branch. Next a `check <n>` line when the post-merge check finishes; its SHA is the plan branch head it ran on. After a FAIL comes a `check <n>-fix<k>` line when the check fix returns, then a new `check <n>` line for the re-run. The `task <n>` line comes last. It goes in only once the task's merge has landed and its check has passed. Its SHA is the merge commit on the plan branch, or the task's own last commit for a task run in place; its status and report path are the implementer's. A FAIL `check` line is cleared by a later PASS `check` line for the same id. A plan from before 0.8.0 (see Wave dispatch) gets only `task` lines, as before.

**On resume** — after compaction, in a new session, or whenever you're unsure what has run — read `progress.md`, `git log` of the plan branch and `git branch --list 'fp/<plan-key>/t*'` before dispatching anything.

- A task with a `task` line is done: do not re-dispatch it.
- A commit on the plan branch without a `task` line (a task run in place, or any task of a plan from before 0.8.0) means the task's checks are pending, not that it is done. Don't re-dispatch the implementer; read its report, run the checks it is owed — your spot-check, or the spec-check on the strict tier, with any fix loop that follows, then the post-task check on a 0.8.0 plan — and add the line only when they pass.
- Classify each task branch `fp/<plan-key>/t<n>` from its tip, `TIP=$(git rev-parse fp/<plan-key>/t<n>)`:
  - **merged** when `git rev-list --min-parents=2 --parents <plan-branch> | awk -v t="$TIP" '{for (i = 3; i <= NF; i++) if ($i == t) f = 1} END {exit !f}'` succeeds (the tip is a merged-in parent of a merge commit on the plan branch);
  - otherwise, **no new commits** when `git merge-base --is-ancestor "$TIP" <plan-branch>` succeeds, and **unmerged commits** when it fails;
  - a merge commit that `git rev-list --min-parents=2 <plan-branch>..fp/<plan-key>/t<n>` prints is classified by the report that covers it, not by its parent count: it is a **merge-fix commit** when `reports/task-<n>-merge<k>.md` names its SHA, and a **fix-round commit** when `reports/task-<n>-fix<k>.md` does. A fix round may merge the plan tip into its branch too. A commit no report names is the task's own work.

| Situation | Owed |
|---|---|
| Task branch with unmerged commits and no merge-fix commits, no `task` line | its checks (your spot-check, or the spec-check on the strict tier), then its merge. Not re-dispatched. A fix-round commit with no `fix <n>-<k>` line: read `reports/task-<n>-fix<k>.md` and add the line first; the checks then cover the fixed branch. |
| Task branch merged, no `task` line | the check run, then the `task` line (the merge came after its checks). A PASS `check <n>` line already in means only the `task` line is owed. |
| Task branch with unmerged merge-fix commits, no `task` line | for each merge-fix commit with no `merge` line, read `reports/task-<n>-merge<k>.md` and add the `merge <n>-<k>` line; then retry the merge. |
| Task branch with no new commits | re-dispatch to the same worktree, telling the implementer it may hold partial edits from an earlier attempt to review or discard. |
| Check-fix commit on the plan branch with no `check <n>-fix<k>` line | read `reports/check-<n>-fix<k>.md`, add the line, then re-run the check. |
| Last `check` line for a task is FAIL | its fix, or a re-run. |
| `task` line in, task worktree or branch still present | the cleanup. |

- A task branch whose worktree is gone is reattached, never recreated (see Task worktrees).
- Review lines tell you where the review loop stands: the last `review` line is the latest round and the number of `review rereview-` lines is what the cap of two has used. A `fix` line with no `review` line after it is owed its re-review — unless two `review rereview-` lines precede it: then the cap is reached, that fix was the capped one, and what it is owed is `fablepowers:verify-done`, not a review.
- A fix commit in `git log` with no `fix` line (compaction while the fixer was in flight) is treated like a task commit without a line: don't re-dispatch the fix; read `reports/integration-fix<k>.md`, add its `fix` line, then do what that line is owed under the rule above (re-review, or verify-done once capped).
- A one-liner fix you made yourself (the only code you write) gets a ledger line like any fix, with `—` as the report and its commit SHA: `fix integration-<k> | <sha7> | DONE | —`.
- If the ledger names a SHA that `git log` doesn't have, the ledger is wrong — trust the log and ask the user if the gap is unclear.

## Wave dispatch

From 0.8.0 on, a plan gives every task a `**Depends on:**` line and a `**Touches:**` line, and names its shared resources in a `## Parallel safety` section (`fablepowers:implementation-plan`). From those you dispatch every task that is ready, each in its own worktree when more than one implementer is in flight, and merge each back after its checks. You work in the plan branch's worktree, the plan worktree; the workspace stays `<plan worktree toplevel>/.fablepowers/<plan>/`.

**Before the first dispatch,** classify the plan, then run the wave script on it:

```bash
bash "<this skill's base dir>/plan-waves" --format <plan-file>
bash "<this skill's base dir>/plan-waves" <plan-file>
```

- **A plan from before 0.8.0:** `--format` prints `pre-0.8.0`, because the plan has neither a `**Touches:**` line nor a `Parallel safety` heading, the two things 0.8.0 introduced. Many older plans do have `**Depends on:**` lines, often in forms the wave script rejects (`Tasks 1, 2`, `T1. Better after T2`), so those lines don't decide it. Don't run the wave script on such a plan. Run its tasks one at a time in the plan worktree, as 0.7.0 did — dispatch, spot-check, `task` line, next task, with no task worktrees, merges or post-merge checks. Say so to the user in one line, and don't edit the approved plan or send it back to plan review.
- On a plan `--format` calls `0.8.0`, exit 0 from the wave script prints one line per wave, `wave <k>: <id>, <id>, …`. The waves show the dependency order; what you dispatch follows the ready rule below, not the wave boundaries.
- Any non-zero exit on a 0.8.0 plan goes back to plan review (`fablepowers:implementation-plan`), with the script's stderr lines as the findings. Don't dispatch from a plan the script rejects.

**Ready and in flight:**

- A task is **ready** when every task on its Depends on line has a `task` line in the ledger, and no in-flight agent holds a `serialize` resource on its Touches line.
- A task implementer, or a merge fix for that task, holds the `serialize` resources on the task's Touches line while it runs.
- `serialize` resources come in two kinds, and the Parallel safety line tells them apart. A **file-contention** resource is only a file that two tasks edit: its line names the file's repository path (`agents/implementer.md — serialize (T4 and T5 both edit it)`). Every other `serialize` resource — a test database, a port, a browser e2e run, a CLI login — is a **run** resource, one that running the tests uses. The post-merge check run and a check fix hold every run resource, and no file-contention resource.
- Every implementer runs a full suite before it commits, whatever its Touches line says, so run resources reach past Touches. A task that touches a `serialize` run resource runs the full suite while it holds it. A task that touches none runs the plan's `pre-commit suite` command instead, the full suite without the serialized parts; a merge fix for that task does the same. Every `isolate` run resource is assigned to every task worktree, each its own instance. The post-merge check runs the true full suite, so every serialized part still runs once per merge. A plan whose full suite uses a `serialize` run resource but names no `pre-commit suite` goes back to plan review.
- **In flight** means any implementer dispatch: tasks, merge fixes and check fixes. It never exceeds the plan header's `**Max parallel:** <n>`, or 4 when the header has none. Reviewers and spec-checks don't count.
- Dispatch all ready tasks together, up to the cap. Dispatch newly ready ones as each task's line goes in or a slot frees up; there is no waiting for a whole wave. When ready tasks contend for one `serialize` resource or for the last slots, plan order decides.

**Where a task runs:**

- A task runs in place, in the plan worktree, only when no other implementer of any kind is in flight and none will be dispatched until it finishes — it is the only task you can dispatch now, and no merge or check is pending. Otherwise it gets a task worktree.
- A task run in place commits directly on the plan branch. Its `task` line carries its own last commit SHA, and its post-task check runs as for a merge. Resume finds it from `git log`, as in 0.7.0.
- No merge goes into the plan worktree while any agent is working in it: a check fix, or a task run in place. Pending merges queue until it is free. The plan worktree also takes one merge at a time: the next queued merge waits for the previous one's PASS `check` line.

**Task worktrees:**

- Task worktrees live inside the plan worktree, at `$PLAN_ROOT/.worktrees/<plan-key>-t<id>`, where `PLAN_ROOT` is `git rev-parse --show-toplevel` of the plan worktree. Every command below runs in the plan worktree. Not under `MAIN_ROOT`: some harnesses refuse a worktree session's writes under the main checkout, and a subagent can't `cd` outside its session directory.
- Before creating the first one, make sure `.worktrees/` is ignored. If `$PLAN_ROOT/.worktrees/.gitignore` doesn't exist, write it with your file-writing tool, holding the single line `*`. It ignores the directory and itself, the way `review-package --init` keeps `.fablepowers/` out of `git status`: nothing to commit, and nothing written under `.git/`, which some harnesses refuse as a sensitive file. Then check:

  ```bash
  git check-ignore -q .worktrees/x
  ```

  It must exit 0; if it doesn't, stop and report. Never add `.worktrees` to the tracked `.gitignore` or commit anything under `.worktrees/`. For task worktrees this replaces `fablepowers:using-git-worktrees`' `.gitignore` commit; that skill's own worktree creation is unchanged.
- Create each task worktree from the plan branch's tip at dispatch time:

  ```bash
  git worktree add -b fp/<plan-key>/t<id> "$PLAN_ROOT/.worktrees/<plan-key>-t<id>" <plan-branch>
  ```

  `<plan-key>` is the workspace name, and `<id>` is the task id in lower case. The branch name is how a resumed session finds a task's work.
- **An existing `fp/<plan-key>/t<id>` branch is resumed, never recreated.** It may hold a crashed run's work, so never delete, reset or `-B` it. Check for it with `git rev-parse --verify --quiet refs/heads/fp/<plan-key>/t<id>` before creating. If `git worktree list` shows its worktree and the directory exists, use it as it is. Otherwise run `git worktree prune`, then reattach the branch without `-b`: `git worktree add "$PLAN_ROOT/.worktrees/<plan-key>-t<id>" fp/<plan-key>/t<id>`. Then do what the resume table owes it.
- A task worktree has only tracked files. Set up its environment as the plan's `worktree env` line in Parallel safety says: for `isolate: <setup step or shared path>`, run that step, or link that path, in the new worktree before dispatch; for `none needed`, do nothing. A plan without the line gets nothing. If a task's tests then fail on a missing ignored file (`.env`, `node_modules`, `.venv`), that is a plan gap; take it to the user rather than copying files on a guess.
- Beyond what Dispatch hygiene requires, a task's dispatch names:
  - the task worktree as the working directory;
  - the instruction to run git as `git -C <task worktree> …` and every other Bash command as `cd <task worktree> && …`, since a subagent's `cd` doesn't persist between calls, and to use absolute paths for Edit and Write. Unless the harness reference says otherwise, git goes through `git -C`, not `cd … && git`, which some permission layers refuse. When it does, the dispatch names the harness's form in so many words; the implementer agent bodies follow a form the dispatch names over their own `git -C` rule;
  - absolute paths for the plan, the spec and the report, with the report under the plan worktree's workspace, never inside the task worktree;
  - the resource instance assigned for each `isolate` resource the task touches and for every `isolate` run resource whatever its Touches line says, as the plan's line for that resource says to assign it;
  - the plan's `pre-commit suite` command as the full suite to run before commit, when the plan names one and the task touches no `serialize` run resource.
- Spot-check a task from a task worktree with `git diff <plan-branch>...fp/<plan-key>/t<id>`.

**Before each merge,** the plan worktree must have no uncommitted changes: `git status --porcelain` prints nothing. If it prints anything, stop and report it to the user. Never stash: the stash stack is shared by every worktree of the repository and by other sessions working in them.

**Merging back,** after the task's checks pass (your spot-check, or a COMPLIANT spec-check on the strict tier):

1. In the plan worktree, run `git merge --no-ff --no-edit fp/<plan-key>/t<id>`. A clean merge is coordination, so you do it. A task may have several commits; its `task` line's SHA is the merge commit.
2. **On a conflict,** run `git merge --abort` and dispatch a merge fix: a `fablepowers:implementer` in the task worktree that merges the plan branch's current tip into the task branch, resolves it, and runs both sides' tests and the full suite. Conflict resolution is implementation work, so the orchestrator never does it, however small the conflict. The dispatch names the two sides (the task branch, and the plan branch with its tip SHA), the conflicting files from the aborted merge, the headings of the merged tasks that touched those files, the plan and spec paths, and the report path `reports/task-<id>-merge<k>.md`, where k counts from 1 for each task.
3. Meanwhile other tasks keep merging. When the merge fix returns, add its `merge <id>-<k>` line and retry the merge; a new conflict means merge fix k+1.

**After each merge,** and after a task run in place commits, run the full suite in the plan worktree. The suite is the plan's full-suite command, or the project's when the plan names none — never the `pre-commit suite`. The run holds every run resource (see Ready and in flight), and no file-contention resource: start it only when no in-flight agent holds a run resource, and dispatch nothing that touches one until it ends.

- The suite must not descend into `.worktrees/`, where other tasks' worktrees sit while it runs (`fablepowers:implementation-plan` has the planner check this). If a check FAILs on files under `.worktrees/`, the failure is not on the plan branch: take it to the user as a plan gap rather than dispatching a check fix.

- Wait on the run the same way implementers wait on a long run (`fablepowers:behavioral-testing`, "Waiting on a long run"). Unless the harness reference names a verified native mechanism, write the run into a script file in your scratch space that runs the suite in the plan worktree with output to `<workspace>/reports/check-<id>.log`, then writes `exit <status>` to `<workspace>/reports/check-<id>.done` (removed beforehand if an earlier run left one):

  ```bash
  cd <plan worktree>
  <full-suite command> > <workspace>/reports/check-<id>.log 2>&1
  echo "exit $?" > <workspace>/reports/check-<id>.done
  ```

  Start it as a background command (on Claude Code, Bash with `run_in_background`), then wait on the marker or the harness's completion notification, in separate bounded calls, each under the harness's tool timeout: `timeout 540 bash -c 'until [ -f <workspace>/reports/check-<id>.done ]; do sleep 5; done'`. Never wait with `pgrep -f <pattern>`, and never with a sleep loop that has no completion condition. The overall wait is capped at the plan's stated suite budget, or 30 minutes when it states none. At the cap, report the hang to the user with the output's tail, and stop waiting.
- The check is PASS when the marker reads `exit 0`, and FAIL otherwise. Append `check <id> | <head7> | PASS|FAIL | —`.
- **A FAIL holds new dispatches** until a check fix lands and a re-run passes. The check fix is a `fablepowers:implementer` in the plan worktree. Its dispatch names the log path, the failing tests as its test obligations (failing before the fix, passing after), and the report path `reports/check-<id>-fix<k>.md`. It commits on the plan branch. Add its `check <id>-fix<k>` line, re-run the check, and add the new `check <id>` line. In-flight tasks continue, and their merges, queued until then, pick up the fix.
- After a PASS, append the task's `task` line.

**Cleanup:** after a task's `task` line goes in, run these from the plan worktree to remove the task's worktree and delete its branch:

```bash
git worktree remove "$PLAN_ROOT/.worktrees/<plan-key>-t<id>"
git branch -d fp/<plan-key>/t<id>
```

If either one refuses, because the worktree has uncommitted changes or git doesn't see the branch as merged, stop and report. Never pass `--force` or `-D` on your own initiative. These worktrees are fablepowers-created, so this skill removes them itself. `fablepowers:finishing-a-development-branch` never removes them: its ownership rule decides only whether the worktree being finished, the plan worktree, is removed. With the plan worktree at `fablepowers:using-git-worktrees`' default, `$MAIN_ROOT/.worktrees/<branch>`, task worktrees sit under that prefix too, and removing the plan worktree deletes the ignored `.worktrees/` inside it, leaving each task branch behind with a stale worktree registration. So remove every one before finishing. While any exist, never run `git clean -x` in the plan worktree; `.worktrees/` is ignored, so it would delete them. A task run in place has nothing to clean up.

## Dispatch hygiene (both flows)

- **Always dispatch the named seat**: the `fablepowers:implementer` agent (or `strict-implementer`, `reviewer`), named explicitly in the dispatch. Never a generic agent that inherits your model: it runs on your model and effort — dispatching it is not a delegation, it is your own session in a second window.
- **Dispatch by reference.** An implementer dispatch names the plan path (absolute, and readable from the implementer's working directory — check it is there when the worktree was created after planning), the task's heading and the spec path; the implementer reads its task, contracts, invariants and test obligations from the plan. The prompt carries only what the plan doesn't: how to run the tests, the commit convention, fix-round findings (or the path to the review report holding them), and the report path. Strict-tier dispatches keep their code-level prompt with the task text inline.
- **Short returns.** Every dispatch names its report path. Use the workspace names above, never a generic `report.md`, `summary.md`, `findings.md` or `analysis.md` — a harness may refuse subagent writes to those basenames (any directory, any case; see the harness reference), and an agent whose write is refused returns its full report inline instead. Implementers return at most 15 lines — `Status`, `SHA`, `Tests` (one line), `Deviations: <count>` plus up to 3 one-line headlines, `Report: <path>`; reviewers return `Verdict`, one line per must-fix (`file:line — headline`), `Declined to judge: <count>`, `Report: <path>`. Keep the full reports in their files; pass a path to the next agent rather than pasting a report into its prompt.
- **No coaching reviewers** — spec-checks included. A reviewer dispatch carries the task or spec, the range, the paths and how to run things; never a pre-rated severity, an instruction to ignore or go easy on something, or the implementer's rationale for a choice. A defect the plan itself mandates is still reported, flagged plan-mandated; take it to the user.
- **Fix-round dispatches carry test obligations.** When an implementer is sent to fix review findings, pass the review report's path and list each must-fix finding's failure scenario as a test obligation — fails on the current code, passes after the fix — and expect before/after evidence per finding in the report (`reports/task-<n>-fix<k>.md`; for integration-review findings, `reports/integration-fix<k>.md`). The full rule is in `fablepowers:integration-review`.
- Implementers may ask questions before starting — answer, then re-dispatch.
- How many tasks run at once, and where, is set by the plan's dependencies and resources: see Wave dispatch.
- Track tasks in your harness's task list; mark complete only after the task's checks pass — the same moment its `task` line goes in.

## Failure handling

If an implementer's report claims success but the diff or test output says otherwise, re-dispatch that task with the strict prompt to a `fablepowers:strict-implementer`, or dispatch a fresh `fablepowers:implementer` with the failure attached. Taking the task yourself is not one of the options.

## Why

The first fork-era audit measured where the work actually happened: the orchestrator's model produced 97% of all output tokens — 78% in the main loop itself, the rest in subagents that inherited its model because no model was set on the spawn. 9 of 13 plan documents recorded "orchestrator implements directly". Only 4 of 12 sessions that wrote a plan dispatched implementers at all. The wording that allowed it is gone; the agents above exist so the model choice lives in a definition file rather than in whatever prompt gets typed at dispatch time. See `docs/rationale.md`.
