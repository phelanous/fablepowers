#!/usr/bin/env bash
# Leave the repo as a run that crashed mid-plan: T1 and T2 ran in parallel,
# T1 was merged (its check and task lines are in the ledger, its worktree and
# branch cleaned up), and fp/demo/t2 holds T2's finished commit (report
# written, worktree directory gone, no ledger line). Both tasks set the one
# shared constant, app/config.py PAGE_SIZE, to their own value (T1 50, T2 100),
# so merging T2 conflicts. T2's spot-check diff against its merge base shows
# only its own change, so the conflict first appears at the merge.
#
# Seeded rather than produced live: live implementers given this plan tend to
# notice the shared constant and sidestep it, and an orchestrator that sees
# both unmerged branches can spot the clash before merging.
# Runs in the fixture repo; env: PLUGIN_ROOT, OUT.
set -euo pipefail
bash "$PLUGIN_ROOT/skills/integration-review/review-package" --init docs/plans/demo.md >/dev/null
printf '\n.worktrees/\n' >> "$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
WS=.fablepowers/demo
mkdir -p "$WS/reports"

task() {  # task <id> <size> <test file> <test body>
  local id="$1" size="$2" file="$3" body="$4" wt="$PWD/.worktrees/demo-t$1"
  git branch "fp/demo/t$id" main
  git worktree add -q "$wt" "fp/demo/t$id"
  sed -i "s/^PAGE_SIZE = 10$/PAGE_SIZE = $size/" "$wt/app/config.py"
  printf '%s\n' "$body" > "$wt/$file"
  git -C "$wt" add -A
  git -C "$wt" commit -qm "feat: T$id, PAGE_SIZE $size"
  cat > "$WS/reports/task-$id.md" <<MD
# T$id report

- **Status:** DONE
- **Commit:** $(git rev-parse --short "fp/demo/t$id") on fp/demo/t$id
- **Change:** \`app/config.py\` \`PAGE_SIZE = $size\`; tests in \`$file\`.
- **Tests:** targeted \`python3 -m unittest\` on \`$file\`: OK. Full \`bash tests/run-all.sh\`: OK.
- **Mutation check:** PAGE_SIZE back to 10: the new test fails; restored, green.
- **Deviations:** none.
MD
}

task 1 50 tests/test_list_view.py 'import unittest

from app.list_view import first_page


class ListViewTest(unittest.TestCase):
    def test_short_list_is_whole_page(self):
        self.assertEqual(first_page([1, 2]), [1, 2])

    def test_page_of_50(self):
        page = first_page(range(1000))
        self.assertEqual(len(page), 50)
        self.assertEqual(page[0], 0)


if __name__ == "__main__":
    unittest.main()'
task 2 100 tests/test_export.py 'import unittest

from app.export import batches


class ExportTest(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(batches([]), [])

    def test_batches_of_100(self):
        out = batches(range(250))
        self.assertEqual([len(b) for b in out], [100, 100, 50])
        self.assertEqual([x for b in out for x in b], list(range(250)))


if __name__ == "__main__":
    unittest.main()'

# T1: merged, checked, ledger lines in, cleaned up.
git merge -q --no-ff --no-edit fp/demo/t1
bash tests/run-all.sh >/dev/null 2>&1
M1="$(git rev-parse --short=7 HEAD)"
printf 'check 1 | %s | PASS | —\ntask 1 | %s | DONE | reports/task-1.md\n' "$M1" "$M1" >> "$WS/progress.md"
git worktree remove "$PWD/.worktrees/demo-t1"
git branch -q -d fp/demo/t1
# T2: the crash took its worktree directory; git lists it until a prune.
rm -rf "$PWD/.worktrees/demo-t2"
