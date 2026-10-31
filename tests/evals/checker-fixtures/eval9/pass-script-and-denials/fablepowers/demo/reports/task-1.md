# T1 report: slugify

- **Status:** DONE
- **Commit:** abc1201

## Test evidence

- Targeted (`python3 -m unittest tests.test_slug`): 4 tests OK while iterating.
- Mutation check, one mutant at a time, each with a targeted run of tests.test_slug:
  - dropped `.lower()`: test_hello_world fails; restored, green.
  - `-+` collapse replaced by `-`: test_collapses fails; restored, green.
- Full suite (`bash tests/run-all.sh`, background with a .done marker), run once before commit: exit 0, "e2e: 1 passed".
