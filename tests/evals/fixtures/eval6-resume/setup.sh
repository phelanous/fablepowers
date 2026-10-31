#!/usr/bin/env bash
# Leave the repo as a crashed run would: the plan workspace exists, .worktrees/
# is in info/exclude, and task T2's branch fp/demo/t2 holds a finished commit
# (its report written) but has no worktree and no ledger line. Runs in the
# fixture repo; env: PLUGIN_ROOT, OUT.
set -euo pipefail
bash "$PLUGIN_ROOT/skills/integration-review/review-package" --init docs/plans/demo.md >/dev/null
# The crashed run had already made .worktrees/ ignored through info/exclude.
printf '
.worktrees/
' >> "$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
WS=.fablepowers/demo
mkdir -p "$WS/reports"
git branch fp/demo/t2 main
git worktree add -q "$PWD/.worktrees/demo-t2" fp/demo/t2
WT="$PWD/.worktrees/demo-t2"
cat > "$WT/mathx/mul.py" <<'PY'
def mul(a, b):
    """Return the product of a and b."""
    return a * b
PY
cat > "$WT/tests/test_mul.py" <<'PY'
import unittest

from mathx.mul import mul


class MulTest(unittest.TestCase):
    def test_positive(self):
        self.assertEqual(mul(2, 3), 6)

    def test_negative(self):
        self.assertEqual(mul(-2, 4), -8)


if __name__ == "__main__":
    unittest.main()
PY
git -C "$WT" add mathx/mul.py tests/test_mul.py
git -C "$WT" commit -qm "feat: mul"
git rev-parse fp/demo/t2 > "$OUT/t2-sha.txt"
cat > "$WS/reports/task-2.md" <<MD
# T2 report: mul

- **Status:** DONE
- **Commit:** $(git rev-parse --short fp/demo/t2) on fp/demo/t2
- **Tests:** targeted \`python3 -m unittest tests.test_mul\`: 2 tests OK. Full \`bash tests/run-all.sh\`: 3 tests OK.
- **Mutation check:** \`return a + b\` in mul: test_positive and test_negative fail; restored, green.
- **Deviations:** none.
MD
# The crash took the worktree directory with it; git still lists it until a prune.
rm -rf "$WT"
