# Plan review: docs/plans/demo.md

**Verdict:** needs changes

## Must-fix

1. **T2 depends on T1 only for the `Color` enum.** `**Depends on:** T1 (the `Color` enum)`: T2 needs the enum type, not T1's code. Pin `Color` in Shared conventions as a contract and make T2 depend on nothing, so T1 and T2 share a wave (plan-review check 2).

## Should-fix

- None.
