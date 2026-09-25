---
name: integration-review
description: Use when feature work is complete and before any merge or PR - RIGID gate; dispatches a fresh-context adversarial reviewer focused on integration seams, the place past bugs actually lived.
---

# Integration Review — RIGID GATE

**No merge, no PR, no "ready" without this review.** This is one of the two rigid gates. Past-session evidence: nearly every real shipped-quality bug was caught here or belonged here — inert config knobs, migration/model parity gaps, deployment config that only worked by accident, contract drift between components.

## The reviewer

Dispatch **one `fablepowers:reviewer`** (Opus, fresh context — never yourself, never an agent that implemented anything in this feature). It inherits nothing from your session. Give it:

- The spec and plan file paths
- The full diff range (`BASE_SHA..HEAD_SHA`) and repo path
- How to run tests and how to run the app/feature

## The mandate (include in the dispatch prompt)

You are an adversarial reviewer. Your job is to find what's wrong, not to appreciate what's right. Assume the per-task work is locally correct — hunt where local correctness doesn't compose:

1. **Run everything.** Full test suite. Then exercise the feature itself — run the app, hit the endpoint, invoke the CLI. Do not review purely by reading.
2. **Knob check:** for every config parameter/flag this feature adds, verify changing it changes behavior. Prove one with a differential run.
3. **Parity checks:** migrations vs. models (test harnesses using `create_all` mask migration gaps — check the migration itself), schema vs. API contract, docs vs. behavior, deployment config (Dockerfiles, compose, env vars) vs. what the code actually reads.
4. **Contract trace:** pick the feature's main data flow and trace it end-to-end across component boundaries; verify each producer's output shape is what the consumer reads.
5. **Spec behaviors:** every success criterion in the spec — observed working, not inferred from code.
6. **Report:** findings ranked by severity, each with file:line and a concrete failure scenario. State explicitly what you executed vs. only read. If you found nothing, say what you tried that failed to break it — "no findings" without evidence of attack is a failed review.

## Re-review cap

At most **two** scoped re-reviews per feature. After the second, stop looping: fix the remaining must-fix items with a `fablepowers:implementer` (yourself only for a one-liner, and say so), run `fablepowers:verify-done`, and tell the user the loop was capped and what remained. A third round has never found what the first two missed; it finds new opinions.

In the second audit, scoped re-reviews found a must-fix about 40% of the time, frequently a regression introduced by the fix commit itself — hence the test obligation on every fix round below.

## After the review

- **Must-fix findings:** dispatch the fix to a `fablepowers:implementer` (yourself only for a one-liner, and say so). For each must-fix finding, the dispatch lists the reviewer's failure scenario as a test obligation: a test that fails on the current code for that scenario and passes after the fix. The implementer reports that before/after evidence per finding. Should-fix items may share one obligation, or be exempted with a stated reason. Then re-dispatch a fresh `fablepowers:reviewer` scoped to the fixes + their blast radius — within the cap above.
- **Judgment-call findings:** decide explicitly and say why; surface disagreements to the user rather than silently dropping them.
- Then proceed to `fablepowers:verify-done` and `fablepowers:finishing-a-development-branch`.
