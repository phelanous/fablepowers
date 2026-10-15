---
name: integration-review
description: Use when feature work is complete and before any merge or PR - RIGID gate; dispatches a fresh-context adversarial reviewer focused on integration seams, the place past bugs actually lived.
---

# Integration Review — RIGID GATE

**No merge, no PR, no "ready" without this review.** This is one of the two rigid gates. Past-session evidence: nearly every real shipped-quality bug was caught here or belonged here — inert config knobs, migration/model parity gaps, deployment config that only worked by accident, contract drift between components.

## The reviewer

Dispatch **one `fablepowers:reviewer`** (frontier tier, fresh context — never yourself, never an agent that implemented anything in this feature). It inherits nothing from your session.

First build the review package. `<base-branch>` is the branch this work merges into — for a stacked branch that's the parent feature branch, not `main`:

```bash
bash "<this skill's base dir>/review-package" <plan-file> <base-branch>
```

The first argument only names the workspace. Work with no plan file passes its spec file instead; work with neither (small or single-task work) passes `@<branch-name>`, which keys the workspace on the branch name with each `/` made a `-` (`@feat/x` → `.fablepowers/feat-x/`, so `@feat/x` and `@feat-x` share a workspace). `@` is only for keys with no file: an `@` name ending in `.md` that names an existing file exits 2 (pass the plain path), and a name starting with `.` (`@.git`) exits 2.

It diffs from `git merge-base <base-branch> HEAD`, not the bare base branch, so base-side commits made after the branch point don't show up as phantom deletions. It writes `<workspace>/review-<mb7>..<head7>.diff` (commit list, `--stat`, `-U10` diff) and prints `wrote <path>: <N> commit(s)`. Exit 2 means a bad argument, an unknown ref, a missing plan file, a key whose name would be empty, `.`, `..` or start with `.`, or an `@` key naming an existing `.md` file; exit 3 means the range is empty or the refs share no history — check the base before dispatching. Nothing is created on a non-zero exit.

Give the reviewer:

- The spec and plan file paths
- The review-package path, plus the repo path
- How to run tests and how to run the app/feature
- The report path: `<workspace>/reports/review-integration.md` (re-reviews: `reports/review-rereview-<k>.md`) — these names exactly; a harness may refuse subagent writes to generic names such as `report.md` (see the harness reference)
- The mandate below

When the reviewer returns, append its round to the ledger `<workspace>/progress.md` before acting on it: `review integration | <head7> | <verdict> | reports/review-integration.md`, or `review rereview-<k> | …` for a re-review. A resumed session reads these lines to know which round ran last and how much of the cap is used.

**What the dispatch never carries:** a pre-rated severity ("probably minor"), an instruction to ignore, skip or not flag something, or the implementer's rationale for a choice ("kept simple on purpose"). Each one tilts the review toward what you already believe, and the reviewer is there because you can't see past that. If the plan itself mandates a defect, the reviewer still reports it, flagged plan-mandated — you take it to the user.

The reviewer writes its full report to the path you named and returns a short form: `Verdict`, one line per must-fix (`file:line — headline`), `Declined to judge: <count>`, `Report: <path>`. Read the full report before deciding anything the short form leaves open, and pass its path — not a pasted copy — to a fixer.

## The mandate (include in the dispatch prompt)

You are an adversarial reviewer. Your job is to find what's wrong, not to appreciate what's right. Assume the per-task work is locally correct — hunt where local correctness doesn't compose:

1. **Run everything.** Full test suite. Then exercise the feature itself — run the app, hit the endpoint, invoke the CLI. Do not review purely by reading.
2. **Knob check:** for every config parameter/flag this feature adds, verify changing it changes behavior. Prove one with a differential run.
3. **Parity checks:** migrations vs. models (test harnesses using `create_all` mask migration gaps — check the migration itself), schema vs. API contract, docs vs. behavior, deployment config (Dockerfiles, compose, env vars) vs. what the code actually reads.
4. **Contract trace:** pick the feature's main data flow and trace it end-to-end across component boundaries; verify each producer's output shape is what the consumer reads.
5. **Spec behaviors:** every success criterion in the spec — observed working, not inferred from code.
6. **Report:** findings ranked by severity, each with file:line and a concrete failure scenario. State explicitly what you executed vs. only read. If you found nothing, say what you tried that failed to break it — "no findings" without evidence of attack is a failed review. End with **Declined to judge**: what you saw but chose not to rule on, and why.

The review package is a map of the change, not evidence: read it first, then still run everything above.

## Re-review cap

At most **two** scoped re-reviews per feature. After the second, stop looping: fix the remaining must-fix items with a `fablepowers:implementer` (yourself only for a one-liner, and say so), log it as `fix integration-3` like any fix round, run `fablepowers:verify-done` — not another review — and tell the user the loop was capped and what remained. A third round has never found what the first two missed; it finds new opinions.

In the second audit, scoped re-reviews found a must-fix about 40% of the time, frequently a regression introduced by the fix commit itself — hence the test obligation on every fix round below.

## After the review

- **Must-fix findings:** dispatch the fix to a `fablepowers:implementer` (yourself only for a one-liner, and say so), passing the review report's path and the report path `<workspace>/reports/integration-fix<k>.md` — `k` is 1 for the fix after the integration review and `k+1` after re-review `k`. When it returns, append `fix integration-<k> | <sha7> | <status> | reports/integration-fix<k>.md` to the ledger; a one-liner you made yourself gets `fix integration-<k> | <sha7> | DONE | —` (no report). For each must-fix finding, the dispatch lists the reviewer's failure scenario as a test obligation: a test that fails on the current code for that scenario and passes after the fix. The implementer reports that before/after evidence per finding. Should-fix items may share one obligation, or be exempted with a stated reason. Then re-dispatch a fresh `fablepowers:reviewer` scoped to the fixes + their blast radius — within the cap above. A re-review gets its own package covering only the fix range: pass the previously reviewed head SHA as `<base-branch>`.
- **Judgment-call findings:** decide explicitly and say why; surface disagreements to the user rather than silently dropping them.
- **Declined to judge:** rule on each item the reviewer set aside — act on it, defer it, or take it to the user. None is dropped silently.
- Then proceed to `fablepowers:verify-done` and `fablepowers:finishing-a-development-branch`.

## Rulings I made

Your final report to the user, before `fablepowers:finishing-a-development-branch`, includes a **Rulings I made** section: every judgment call you made on the user's behalf during execution and review —

- each declined-to-judge item and what you decided,
- must-fix items left over when the re-review cap stopped the loop,
- plan conflicts you resolved,
- plan-mandated defects you kept rather than fixed.

One bullet each, naming the call and what it costs if it's wrong. Write it for a phone: at most 20 words per bullet, no tables, no file paths or code. If you made no such calls, say so in one line.
