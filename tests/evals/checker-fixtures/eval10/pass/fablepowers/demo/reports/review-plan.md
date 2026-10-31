# Plan review: docs/plans/demo.md

**Verdict:** needs changes

## Must-fix

1. **T2 depends on T1 only for the `Color` enum.** `**Depends on:** T1 (the `Color` enum)`: T2 needs the enum type, not T1's code. Pin `Color` in Shared conventions as a contract and make T2 depend on nothing, so T1 and T2 share a wave (plan-review check 2).
2. **T3 has no Depends on line.** `plan-waves` exits 2 with `plan-waves: no-depends: T3 (line 45) has no **Depends on:** line` (checks 1 and 4).

## Should-fix

- None.
