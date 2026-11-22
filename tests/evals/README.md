# Live evals

Headless Claude Code runs on small fixture repos: evals 6–10 cover the 0.8.0
parallel-execution rules (that spec's "How we'll know it works", items 6–10),
evals 11 and up the 0.8.1 review-cycle rules (the review-cycle-cap spec's
items 1–5). They are **manual runs, not
part of the offline suites or CI**. Each run bills your Claude Code login.

| Eval | What it runs | What the checker asserts |
|---|---|---|
| `eval6` | two independent tasks and one dependent task | the two dispatches in one message, each naming its own `.worktrees/` task worktree, with overlapping active intervals; the dependent task dispatched after both `task` lines; `--no-ff` merges, each followed by a `check` line; worktrees and branches gone; `.worktrees/` ignored without a tracked change (`git check-ignore` succeeds, no `.worktrees` entry in `.gitignore` committed or uncommitted, nothing under `.worktrees/` committed). Wave-1 concurrency is printed as a signal. |
| `eval6-resume` | `eval6` again, starting from a crashed run's state: `.worktrees/.gitignore` (`*`) already written, and an `fp/demo/t2` branch with a finished commit whose worktree directory is gone | T2 is not re-dispatched; its branch is never recreated, deleted or reset, and its commit is merged; then the `eval6` merge, check, cleanup and stop assertions |
| `eval7` | two tasks that set the one constant `app/config.py` `SIZES` to different values (T1 `"page": 50`, T2 `"batch": 100`, on adjacent lines, so the merge conflicts while neither task's own diff is wrong), started from a crashed run's state: T1 merged with its ledger lines, T2's finished commit on `fp/demo/t2`, `.worktrees/.gitignore` (`*`) already written. The conflict is seeded because live implementers sidestep a shared constant and an orchestrator seeing both branches unmerged can catch the clash before merging | `git merge --abort` and a merge-fix dispatch; a `merge` ledger line after the fix returns; no orchestrator Edit or Write to the conflicted file; no orchestrator Bash naming it, or using `--ours`/`--theirs`, between the abort and the fix's return; the resolving merge commit on the task branch |
| `eval8` | two independent tasks sharing the `e2e — serialize` resource, and a third independent task with `Touches: none` as the control; the plan names a `pre-commit suite` without the e2e | both serialized tasks dispatched; their active intervals never overlap; the control's interval overlaps one of theirs (so a one-at-a-time fallback fails); the control's implementer runs the pre-commit suite and never the e2e, read through any script it wrote (integration review M2) |
| `eval9` | one task whose full suite has a 3-minute e2e step named `playwright test`, while the driver keeps a decoy process of the same name alive | the implementer's waits use its own `.done` marker or PID, never `pgrep -f`; it finishes while the decoy is alive; its report labels targeted and full runs and shows mutant runs; one or two full-suite runs |
| `eval10` | plan review of a plan with an enum-only dependency (T2 on T1) and a task with no Depends on line (T3) | a `fablepowers:reviewer` dispatch; its report flags both; nothing executed |
| `eval11` | finish the branch `feat/demo` for merging into `main`: its seeded ledger's review cycle 1 used its cap (`review integration`, two `review rereview-` lines, `fix integration-3`), then one later commit adds `neg` with a test | exactly one `fablepowers:reviewer` dispatch, whose review-package path starts at the seeded reviewed head (the SHA on the latest `review` line), not the merge-base; a `review integration-c2` ledger line with `reports/review-integration-c2.md`; no merge, PR or push command anywhere in the transcript; the run ends on its own with the ledger in its final message |
| `eval11-clean` | as `eval11`, but cycle 1 ended at the integration review with no must-fix and no re-reviews | as `eval11` |
| `eval11-rebase` | as `eval11-clean` with no later commit, and cycle 1's review package in the workspace (its name records the reviewed range's start); then `main` gains an unrelated commit and `feat/demo` is rebased onto it with no content change | no reviewer dispatch; a comparison call that ran: `git diff-tree` (the shipped test pipes it to `git hash-object --stdin`; an earlier wording did not), or `git patch-id` (any flags), which saved runs on earlier wordings used; a refused call doesn't count; a `review carried \| <sha7> \| patch-identical \| —` line whose SHA is the rebased image of the reviewed head (here also HEAD; the checker compares with the image setup.sh recorded); no merge, PR or push command; the ledger in the final message |
| `eval12` | resume `feat/demo`: cycle 1 used its cap (`review integration`, two `review rereview-` lines), and `fix integration-3` is committed and logged at HEAD, not yet verified; nothing after it | no `fablepowers:reviewer` dispatch; the ledger's current cycle keeps exactly two re-review lines (no third re-review, no new cycle opened); the session runs the full suite itself (verify-done; a script it wrote is read through); the final message says the review loop was capped; no merge, PR or push command; the ledger in the final message |
| `eval12-c2` | resume `feat/demo`: cycle 1 capped, a later commit, `review integration-c2` with a must-fix, then `fix integration-c2-1` at HEAD with its report | exactly one `fablepowers:reviewer` dispatch, whose review-package path starts at the SHA on the `review integration-c2` line; a `review rereview-c2-1` ledger line with `reports/review-rereview-c2-1.md`; no merge, PR or push command; the ledger in the final message |

Every orchestrator prompt names its stop, and each checker asserts that it
happened. Evals 6–9 stop after the last task's `task` line, before integration
review; eval 10 after the plan reviewer returns. The eval 11 states run integration
review where it is owed and stop immediately before the merge, PR or push
command itself; their prompt never mentions reviews, cycles or what may be
owed. The eval 12 states resume an earlier session, do what the ledger says is
owed next and stop, with no merge, PR or push; their prompt doesn't name what
is owed either. Their ledgers are written by `setup.sh` (the SHAs depend on commit time),
which records the seeded reviewed head in `reviewed-head.txt`, and for the
rebase state its rebased image in `reviewed-image.txt`, in the output
directory for the checker.

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
- `EVAL_PLUGIN_DIR=<dir>` loads another plugin checkout as `--plugin-dir`
  (default: this one), e.g. a `git worktree` of an older release for a baseline
  run. The fixture's `setup.sh` and checker still come from this checkout. A
  directory without `.claude-plugin/plugin.json` exits 2 before any run.
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

**Manual-run status.** Run evals 6–10 after a change to `fablepowers:subagent-execution`,
`fablepowers:implementation-plan`, `fablepowers:behavioral-testing` or the implementer
agents, and the eval 11 and eval 12 states after a change to `fablepowers:integration-review`,
`fablepowers:subagent-execution`'s resume rule, `fablepowers:workflow`,
`fablepowers:finishing-a-development-branch` or the reviewer agent; record the result. A failing assertion is evidence about the skill
text or the checker; don't loosen the assertion to make it pass.

## Offline checker tests

```sh
bash tests/evals/test-checkers.sh
```

Runs each checker on the synthetic transcripts in `checker-fixtures/<eval>/`:
the `pass` case must pass, and each doctored case must fail on exactly the
assertions its `expect` file names, one per line. Every assertion has a case
that names it alone; a case naming several replays an older release's
behaviour (eval 11's `ready-no-c2-review` and `merged-no-c2-review`, the 0.8.0
orchestrator that treats the spent cap as exempting later work) or a
hypothetical one (eval 12-c2's `treated-as-capped`, a lifetime count that
reads cycle 2's cap as spent; the live 0.8.0 baseline did not do this, and
passed). It also builds each eval 11 and eval 12 state from its `setup.sh` in a
temporary repo and checks the result (reviewed head, commits past it, the
identical rebase and its recorded range start, the owed fix at HEAD). Limit: `eval11-rebase` checks the carried line and that the comparison ran, not that the package chain was consulted; its saved runs before `97ae38b` had no package in their workspace. `checker-fixtures/build.py` generates the
cases; after changing it, run `python3 -I tests/evals/checker-fixtures/build.py`
to rewrite them (the test fails while they differ). No login needed.
