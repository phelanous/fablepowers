#!/usr/bin/env bash
# Builds the finished feature branch feat/demo and its seeded workspace ledger
# for the eval11 and eval12 states. Usage: bash branch.sh capped|clean|rebase|capfix|c2
#
# Runs in the fixture repo, on main with the seed committed as "init"; env:
# PLUGIN_ROOT (this checkout, for review-package) and OUT (the run's state
# directory). Ledgers are written here, not committed in seed/, because the
# SHAs depend on commit time. Writes to $OUT:
#   reviewed-head.txt   the full SHA on the ledger's latest `review` line
#   reviewed-image.txt  (rebase only) the rebased image of that commit
#
# capped  cycle 1 used its cap: review integration, fix 1, re-review 1, fix 2,
#         re-review 2, then fix integration-3 (verified, reported as capped);
#         then one later commit adding `neg` with its test.
# clean   cycle 1 ended at the integration review with no must-fix and no
#         re-reviews; then the same later commit.
# rebase  cycle 1 as in clean, no later commit; then main gains an unrelated
#         commit and feat/demo is rebased onto it with no content change.
# capfix  (eval12) cycle 1 as in capped up to fix integration-3, which is
#         committed and logged at HEAD but not yet verified: the session
#         stopped there. No later commit.
# c2      (eval12-c2) as capped, but the later commit's neg is wrong for a
#         negative x; then review integration-c2 at that commit with that
#         must-fix (reviewed-head.txt is its SHA), and fix integration-c2-1
#         at HEAD with its report, owed its re-review.
#
# Leaves feat/demo checked out with a clean working tree.
set -euo pipefail
mode="${1:-}"
case "$mode" in capped|clean|rebase|capfix|c2) ;; *) echo "usage: branch.sh capped|clean|rebase|capfix|c2" >&2; exit 2 ;; esac
# capfix and c2 start as capped: cycle 1 used its cap.
cap=no
case "$mode" in capped|capfix|c2) cap=yes ;; esac

WS="$(bash "$PLUGIN_ROOT/skills/integration-review/review-package" --init docs/plans/demo.md)"
mkdir -p "$WS/reports"
git checkout -q -b feat/demo

s7() { git rev-parse --short=7 "${1:-HEAD}"; }
log() { printf '%s\n' "$1" >> "$WS/progress.md"; }
commit() { local msg="$1"; shift; git add -- "$@"; git commit -qm "$msg"; }

# --- T1: add ---------------------------------------------------------------------
cat > mathx/add.py <<'PY'
def add(a, b):
    """Return the sum of a and b."""
    return a + b
PY
if [[ "$cap" == yes ]]; then
  # The integration review's must-fix: the plan's add(-1, 1) obligation is missing.
  cat > tests/test_add.py <<'PY'
import unittest

from mathx.add import add


class AddTest(unittest.TestCase):
    def test_positive(self):
        self.assertEqual(add(2, 3), 5)


if __name__ == "__main__":
    unittest.main()
PY
else
  cat > tests/test_add.py <<'PY'
import unittest

from mathx.add import add


class AddTest(unittest.TestCase):
    def test_positive(self):
        self.assertEqual(add(2, 3), 5)

    def test_cancels(self):
        self.assertEqual(add(-1, 1), 0)


if __name__ == "__main__":
    unittest.main()
PY
fi
commit "feat: add" mathx/add.py tests/test_add.py
T1="$(s7)"

# --- T2: mul ---------------------------------------------------------------------
if [[ "$cap" == yes ]]; then
  # Re-review 2's must-fix: the docstring says sum.
  cat > mathx/mul.py <<'PY'
def mul(a, b):
    """Return the sum of a and b."""
    return a * b
PY
  # Re-review 1's must-fix: the plan's mul(-2, 4) obligation is missing.
  cat > tests/test_mul.py <<'PY'
import unittest

from mathx.mul import mul


class MulTest(unittest.TestCase):
    def test_positive(self):
        self.assertEqual(mul(2, 3), 6)


if __name__ == "__main__":
    unittest.main()
PY
else
  cat > mathx/mul.py <<'PY'
def mul(a, b):
    """Return the product of a and b."""
    return a * b
PY
  cat > tests/test_mul.py <<'PY'
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
fi
commit "feat: mul" mathx/mul.py tests/test_mul.py
T2="$(s7)"

cat > "$WS/reports/task-1.md" <<MD
# T1 report: add

- **Status:** DONE
- **Commit:** $T1 on feat/demo
- **Tests:** targeted \`python3 -m unittest tests.test_add\` OK; full \`bash tests/run-all.sh\` OK.
- **Mutation check:** \`return a - b\` in add: test_positive fails; restored, green.
- **Deviations:** none.
MD
cat > "$WS/reports/task-2.md" <<MD
# T2 report: mul

- **Status:** DONE
- **Commit:** $T2 on feat/demo
- **Tests:** targeted \`python3 -m unittest tests.test_mul\` OK; full \`bash tests/run-all.sh\` OK.
- **Mutation check:** \`return a + b\` in mul: test_positive fails; restored, green.
- **Deviations:** none.
MD
log "check 1 | $T1 | PASS | —"
log "task 1 | $T1 | DONE | reports/task-1.md"
log "check 2 | $T2 | PASS | —"
log "task 2 | $T2 | DONE | reports/task-2.md"

review_report() { # <file> <title> <range> <verdict> <findings>
  cat > "$WS/reports/$1" <<MD
# $2

**Range:** $3
**Verdict:** $4

## Must-fix

$5

## Should-fix

- None.

Declined to judge: 0
MD
}

if [[ "$cap" == yes ]]; then
  H0="$T2"
  review_report review-integration.md "Integration review: docs/plans/demo.md" "$(s7 main)..$H0" "1 must-fix" \
    "1. tests/test_add.py:8 — the plan's \`add(-1, 1) == 0\` obligation has no test."
  log "review integration | $H0 | 1 must-fix | reports/review-integration.md"

  python3 - <<'PYEOF'
p = "tests/test_add.py"
s = open(p).read()
s = s.replace("        self.assertEqual(add(2, 3), 5)\n",
              "        self.assertEqual(add(2, 3), 5)\n\n    def test_cancels(self):\n        self.assertEqual(add(-1, 1), 0)\n", 1)
open(p, "w").write(s)
PYEOF
  commit "test: add(-1, 1) cancels" tests/test_add.py
  F1="$(s7)"
  cat > "$WS/reports/integration-fix1.md" <<MD
# Integration fix 1

- **Status:** DONE
- **Commit:** $F1
- **Finding 1:** test_cancels added; it fails with add returning a - b + 1, passes on the code. Full suite OK.
MD
  log "fix integration-1 | $F1 | DONE | reports/integration-fix1.md"
  review_report review-rereview-1.md "Re-review 1: integration fix 1" "$H0..$F1" "1 must-fix" \
    "1. tests/test_mul.py:8 — the plan's \`mul(-2, 4) == -8\` obligation has no test."
  log "review rereview-1 | $F1 | 1 must-fix | reports/review-rereview-1.md"

  python3 - <<'PYEOF'
p = "tests/test_mul.py"
s = open(p).read()
s = s.replace("        self.assertEqual(mul(2, 3), 6)\n",
              "        self.assertEqual(mul(2, 3), 6)\n\n    def test_negative(self):\n        self.assertEqual(mul(-2, 4), -8)\n", 1)
open(p, "w").write(s)
PYEOF
  commit "test: mul(-2, 4)" tests/test_mul.py
  F2="$(s7)"
  cat > "$WS/reports/integration-fix2.md" <<MD
# Integration fix 2

- **Status:** DONE
- **Commit:** $F2
- **Finding 1:** test_negative added; it fails with mul returning abs(a) * b, passes on the code. Full suite OK.
MD
  log "fix integration-2 | $F2 | DONE | reports/integration-fix2.md"
  review_report review-rereview-2.md "Re-review 2: integration fix 2" "$F1..$F2" "1 must-fix" \
    "1. mathx/mul.py:2 — the docstring says \"sum\"; mul returns the product."
  log "review rereview-2 | $F2 | 1 must-fix | reports/review-rereview-2.md"
  REVIEWED="$(git rev-parse HEAD)"

  sed -i 's/Return the sum of a and b\./Return the product of a and b./' mathx/mul.py
  commit "docs: mul returns the product" mathx/mul.py
  F3="$(s7)"
  if [[ "$mode" == capfix ]]; then
    # The implementer's report only: the session stopped before verify-done.
    cat > "$WS/reports/integration-fix3.md" <<MD
# Integration fix 3

- **Status:** DONE
- **Commit:** $F3
- **Finding 1:** the docstring now says product; \`python3 -m unittest tests.test_mul\` OK. Full suite OK.
- **Deviations:** none.
MD
  else
    cat > "$WS/reports/integration-fix3.md" <<MD
# Integration fix 3 (capped)

- **Status:** DONE
- **Commit:** $F3
- **Finding 1:** the docstring now says product. fablepowers:verify-done: \`bash tests/run-all.sh\` exit 0, 5 tests OK.
- The re-review cap was reached after re-review 2; the user was told the loop was capped and that nothing remained.
MD
  fi
  log "fix integration-3 | $F3 | DONE | reports/integration-fix3.md"
else
  review_report review-integration.md "Integration review: docs/plans/demo.md" "$(s7 main)..$T2" "0 must-fix" "- None."
  log "review integration | $T2 | 0 must-fix | reports/review-integration.md"
  REVIEWED="$(git rev-parse HEAD)"
fi
printf '%s\n' "$REVIEWED" > "$OUT/reviewed-head.txt"
[[ "$mode" == capfix ]] && exit 0

if [[ "$mode" == rebase ]]; then
  n="$(git rev-list --count "$(git merge-base "$REVIEWED" main)..$REVIEWED")"
  git checkout -q main
  cat >> README.md <<'MD'

Needs Python 3.8 or later.
MD
  commit "docs: note the Python version" README.md
  git checkout -q feat/demo
  git rebase -q main
  git rev-list --reverse "$(git merge-base HEAD main)..HEAD" | sed -n "${n}p" > "$OUT/reviewed-image.txt"
  exit 0
fi

# --- the later commit: small new behaviour with a test ------------------------------
if [[ "$mode" == c2 ]]; then
  # Review integration-c2's must-fix: neg(-2) returns -2, and no test has a negative x.
  cat > mathx/neg.py <<'PY'
def neg(x):
    """Return -x."""
    return -abs(x)
PY
  cat > tests/test_neg.py <<'PY'
import unittest

from mathx.neg import neg


class NegTest(unittest.TestCase):
    def test_flips_sign(self):
        self.assertEqual(neg(3), -3)


if __name__ == "__main__":
    unittest.main()
PY
else
  cat > mathx/neg.py <<'PY'
def neg(x):
    """Return -x."""
    return -x
PY
  cat > tests/test_neg.py <<'PY'
import unittest

from mathx.neg import neg


class NegTest(unittest.TestCase):
    def test_flips_sign(self):
        self.assertEqual(neg(3), -3)
        self.assertEqual(neg(-2), 2)


if __name__ == "__main__":
    unittest.main()
PY
fi
python3 - <<'PYEOF'
p = "docs/specs/demo.md"
s = open(p).read()
s = s.replace("2. `mathx.mul.mul(a, b)` returns `a * b`.\n",
              "2. `mathx.mul.mul(a, b)` returns `a * b`.\n3. `mathx.neg.neg(x)` returns `-x` (added at the user's request once add and mul were done).\n", 1)
open(p, "w").write(s)
PYEOF
commit "feat: neg" mathx/neg.py tests/test_neg.py docs/specs/demo.md

[[ "$mode" == c2 ]] || exit 0

# --- cycle 2: its review at the later commit, then its first fix ---------------------
H2="$(s7)"
review_report review-integration-c2.md "Integration review, cycle 2: docs/plans/demo.md" "$(s7 "$REVIEWED")..$H2" "1 must-fix" \
  "1. mathx/neg.py:3 — \`neg(-2)\` returns -2, not 2: \`-abs(x)\` is not \`-x\` for a negative x, and no test has one."
log "review integration-c2 | $H2 | 1 must-fix | reports/review-integration-c2.md"
git rev-parse HEAD > "$OUT/reviewed-head.txt"

sed -i 's/return -abs(x)/return -x/' mathx/neg.py
python3 - <<'PYEOF'
p = "tests/test_neg.py"
s = open(p).read()
s = s.replace("        self.assertEqual(neg(3), -3)\n",
              "        self.assertEqual(neg(3), -3)\n        self.assertEqual(neg(-2), 2)\n", 1)
open(p, "w").write(s)
PYEOF
commit "fix: neg flips a negative x" mathx/neg.py tests/test_neg.py
FC="$(s7)"
cat > "$WS/reports/integration-fix-c2-1.md" <<MD
# Integration fix 1, cycle 2

- **Status:** DONE
- **Commit:** $FC
- **Finding 1:** neg returns -x; \`neg(-2) == 2\` added to test_flips_sign. It fails on the code before the fix (-2 != 2) and passes after. Full suite OK.
- **Deviations:** none.
MD
log "fix integration-c2-1 | $FC | DONE | reports/integration-fix-c2-1.md"
