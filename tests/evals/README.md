# Live evals

Headless Claude Code runs of the 0.8.0 parallel-execution rules on small fixture
repos: spec "How we'll know it works", items 6–10. They are **manual runs, not
part of the offline suites or CI**. Each run bills your Claude Code login.

| Eval | What it runs | What the checker asserts |
|---|---|---|
| `eval6` | two independent tasks and one dependent task | the two dispatches in one message, each naming its own `.worktrees/` task worktree, with overlapping active intervals; the dependent task dispatched after both `task` lines; `--no-ff` merges, each followed by a `check` line; worktrees and branches gone; `.worktrees/` ignored without a tracked change (`git check-ignore` succeeds, no `.worktrees` entry in `.gitignore` committed or uncommitted, nothing under `.worktrees/` committed). Wave-1 concurrency is printed as a signal. |
| `eval6-resume` | `eval6` again, starting from a crashed run's state: `.worktrees/.gitignore` (`*`) already written, and an `fp/demo/t2` branch with a finished commit whose worktree directory is gone | T2 is not re-dispatched; its branch is never recreated, deleted or reset, and its commit is merged; then the `eval6` merge, check, cleanup and stop assertions |
| `eval7` | two tasks that set the one constant `app/config.py` `SIZES` to different values (T1 `"page": 50`, T2 `"batch": 100`, on adjacent lines, so the merge conflicts while neither task's own diff is wrong), started from a crashed run's state: T1 merged with its ledger lines, T2's finished commit on `fp/demo/t2`, `.worktrees/.gitignore` (`*`) already written. The conflict is seeded because live implementers sidestep a shared constant and an orchestrator seeing both branches unmerged can catch the clash before merging | `git merge --abort` and a merge-fix dispatch; a `merge` ledger line after the fix returns; no orchestrator Edit or Write to the conflicted file; no orchestrator Bash naming it, or using `--ours`/`--theirs`, between the abort and the fix's return; the resolving merge commit on the task branch |
| `eval8` | two independent tasks sharing the `e2e — serialize` resource, and a third independent task with `Touches: none` as the control; the plan names a `pre-commit suite` without the e2e | both serialized tasks dispatched; their active intervals never overlap; the control's interval overlaps one of theirs (so a one-at-a-time fallback fails); the control's implementer runs the pre-commit suite and never the e2e, read through any script it wrote (integration review M2) |
| `eval9` | one task whose full suite has a 3-minute e2e step named `playwright test`, while the driver keeps a decoy process of the same name alive | the implementer's waits use its own `.done` marker or PID, never `pgrep -f`; it finishes while the decoy is alive; its report labels targeted and full runs and shows mutant runs; one or two full-suite runs |
| `eval10` | plan review of a plan with an enum-only dependency (T2 on T1) and a task with no Depends on line (T3) | a `fablepowers:reviewer` dispatch; its report flags both; nothing executed |

Every orchestrator prompt stops after the last task's `task` line (eval 10: after
the reviewer returns), before integration review, and each checker asserts that
the stop happened.

## Running

```sh
bash tests/evals/run-eval.sh eval10      # one at a time; claude-cli is a serialize resource
```

The driver copies `fixtures/<eval>/seed/` into a fresh `mktemp -d` as a git repo,
runs the fixture's `setup.sh`, then runs `claude -p` there with this checkout as
`--plugin-dir`, the installed plugin disabled
(`--settings '{"enabledPlugins":{"fablepowers@fablepowers":false}}'`),
`--permission-mode acceptEdits` and an allowlist (never
`--dangerously-skip-permissions`). Edit and Write stay under acceptEdits, inside
the fixture repo. Known limit: in `-p`, Claude Code 2.1.306 denies a Bash
command holding a variable or a `( … )` group under any pattern rule ("can't be
checked before it runs"), so the skills put a long run in a script file that
writes its own `.done` marker and start it with `run_in_background`. Writes
under `.git/` are refused as sensitive files, which is why task worktrees are
ignored through `.worktrees/.gitignore`. The driver prints every denial; an
agent that hits one must find another way. It saves the transcript and the repo's state
to `<tmp>/out/`, runs `post.sh`, then `check.py`, and prints each assertion with
the run's cost, turn count and any permission denials. Exit 0 is a pass, 1 a
fail, 2 a usage or setup error.

- `EVAL_RECHECK=<out-dir> bash tests/evals/run-eval.sh <eval>` re-runs only the
  checker on an earlier run's output.
- `EVAL_MAX_BUDGET` lowers the cap; it can't raise it above $3.
- The temp directory is kept and its path printed. It holds the transcript,
  which carries your CLAUDE.md, environment and anything else in the session's
  context, so don't commit it. Only synthetic fixtures are committed.

**Auth.** The runs use your Claude Code login (`claude auth status`). Headless
`claude -p` keeps its own auth state; if it reports not logged in, run `claude`
once interactively. Your user settings and hooks still apply: a user PreToolUse
hook that blocks certain commands affects the evals too. The eval 9 checker
reads `pgrep -f` from the tool calls the agent made, so a blocked attempt still
counts.

**Cost.** Each run is capped at `--max-budget-usd 3` and the fixture's
`max-turns`. A two-implementer dispatch costs about $0.80 before any real work
(T0 spike). The first live runs (Claude Code 2.1.306, Opus orchestrator and
implementers) cost $0.87–1.71 each; the 0.8.0 plan's T7 report has the
per-eval figures and results.

**Manual-run status.** Run each eval after a change to `fablepowers:subagent-execution`,
`fablepowers:implementation-plan`, `fablepowers:behavioral-testing` or the implementer
agents, and record the result. A failing assertion is evidence about the skill
text or the checker; don't loosen the assertion to make it pass.

## Offline checker tests

```sh
bash tests/evals/test-checkers.sh
```

Runs each checker on the synthetic transcripts in `checker-fixtures/<eval>/`:
the `pass` case must pass, and each doctored case must fail on exactly the one
assertion its `expect` file names. `checker-fixtures/build.py` generates the
cases; after changing it, run `python3 -I tests/evals/checker-fixtures/build.py`
to rewrite them (the test fails while they differ). No login needed.
