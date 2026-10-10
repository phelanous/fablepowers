#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# REVIEW_PACKAGE overrides the script under test (used for mutation checks on a copy).
SCRIPT_UNDER_TEST="${REVIEW_PACKAGE:-$REPO_ROOT/skills/integration-review/review-package}"

FAILURES=0
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# Isolate from the user's git config (signing, hooks, default branch names).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

pass() {
  echo "  [PASS] $1"
}

fail() {
  echo "  [FAIL] $1"
  FAILURES=$((FAILURES + 1))
}

assert_eq() {
  local actual="$1" expected="$2" description="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$description"
  else
    fail "$description (expected: $expected, got: $actual)"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" description="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    pass "$description"
  else
    fail "$description (expected to contain: $needle)"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" description="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    fail "$description (unexpectedly contains: $needle)"
  else
    pass "$description"
  fi
}

# run_rp <dir> <args...> — runs the script via bash in <dir>; sets RP_OUT
# (combined output) and RP_EXIT; never aborts on a non-zero exit.
run_rp() {
  local dir="$1"
  shift
  set +e
  RP_OUT=$(cd "$dir" && bash "$SCRIPT_UNDER_TEST" "$@" 2>&1)
  RP_EXIT=$?
  set -e
}

# Toy repo: main has a.txt, b.txt and docs/plan.md. Branch `feature` edits
# a.txt and adds c.txt. After the branch point, main edits b.txt and adds
# d.txt — files the feature never touched. Leaves `feature` checked out.
setup_repo() {
  REPO="$TEST_ROOT/repo-$1"
  mkdir -p "$REPO/docs"
  git -C "$REPO" init -q -b main
  echo a > "$REPO/a.txt"
  echo b > "$REPO/b.txt"
  echo "# plan" > "$REPO/docs/plan.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m init
  git -C "$REPO" checkout -q -b feature
  echo a2 > "$REPO/a.txt"
  echo c > "$REPO/c.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "feature work"
  git -C "$REPO" checkout -q main
  echo b2 > "$REPO/b.txt"
  echo d > "$REPO/d.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "main moves on"
  git -C "$REPO" checkout -q feature
}

# files_changed_section <file> — the text between "## Files changed" and "## Diff".
files_changed_section() {
  sed -n '/^## Files changed$/,/^## Diff$/p' "$1"
}

echo "Test 1: base moved past the branch point -> package is MB..HEAD, no phantom changes"
setup_repo t1
run_rp "$REPO" docs/plan.md main
assert_eq "$RP_EXIT" "0" "exits 0"
MB7=$(git -C "$REPO" rev-parse --short=7 "$(git -C "$REPO" merge-base main feature)")
HEAD7=$(git -C "$REPO" rev-parse --short=7 HEAD)
PKG="$REPO/.fablepowers/plan/review-$MB7..$HEAD7.diff"
assert_eq "$RP_OUT" "wrote $PKG: 1 commit(s)" "prints the package path (named review-<mb7>..<head7>.diff) and commit count"
# Content checks read whichever file the script reports, independent of its name.
WROTE=${RP_OUT#wrote }
WROTE=${WROTE%: *}
if [ -f "$WROTE" ]; then
  PKG=$WROTE
  pass "package file exists at the reported path"
  SECTION=$(files_changed_section "$PKG")
  assert_contains "$SECTION" "a.txt" "Files changed lists the feature's edited file"
  assert_contains "$SECTION" "c.txt" "Files changed lists the feature's added file"
  assert_not_contains "$SECTION" "b.txt" "Files changed omits base-only edit (b.txt)"
  assert_not_contains "$SECTION" "d.txt" "Files changed omits base-only addition (no phantom deletion of d.txt)"
  assert_contains "$(cat "$PKG")" "feature work" "Commits section lists the feature commit"
  assert_not_contains "$(cat "$PKG")" "main moves on" "Commits section omits base-only commit"
  for s in "## Commits" "## Files changed" "## Diff"; do
    assert_contains "$(cat "$PKG")" "$s" "package has section '$s'"
  done
else
  fail "package file exists at the reported path (missing: $WROTE)"
fi
# Explicit head argument gives the same package.
PKG="$REPO/.fablepowers/plan/review-$MB7..$HEAD7.diff"
git -C "$REPO" checkout -q main
run_rp "$REPO" docs/plan.md main feature
assert_eq "$RP_OUT" "wrote $PKG: 1 commit(s)" "explicit HEAD argument packages that ref, not the checkout"
git -C "$REPO" checkout -q feature

echo "Test 2: empty range and unrelated histories -> exit 3"
setup_repo t2
run_rp "$REPO" docs/plan.md feature
assert_eq "$RP_EXIT" "3" "empty range (base == head) exits 3"
run_rp "$REPO" docs/plan.md feature feature~1
assert_eq "$RP_EXIT" "3" "head is an ancestor of base (MB..head empty) exits 3"
git -C "$REPO" checkout -q --orphan lonely
git -C "$REPO" rm -rq --cached . >/dev/null
echo z > "$REPO/z.txt"
git -C "$REPO" add z.txt
git -C "$REPO" commit -q -m lonely
run_rp "$REPO" "$REPO/docs/plan.md" main lonely
assert_eq "$RP_EXIT" "3" "unrelated histories (no merge-base) exit 3"
assert_contains "$RP_OUT" "no common history" "unrelated histories explain themselves"

echo "Test 3: bad arguments -> exit 2"
setup_repo t3
run_rp "$REPO" docs/plan.md no-such-branch
assert_eq "$RP_EXIT" "2" "unknown base ref exits 2"
run_rp "$REPO" docs/plan.md main no-such-head
assert_eq "$RP_EXIT" "2" "unknown head ref exits 2"
run_rp "$REPO" docs/missing.md main
assert_eq "$RP_EXIT" "2" "missing plan file exits 2"
run_rp "$REPO" --init docs/missing.md
assert_eq "$RP_EXIT" "2" "--init with missing plan file exits 2"
run_rp "$REPO" docs/plan.md
assert_eq "$RP_EXIT" "2" "too few arguments exits 2"
run_rp "$REPO" docs/plan.md main feature extra
assert_eq "$RP_EXIT" "2" "too many arguments exits 2"
mkdir -p "$TEST_ROOT/not-a-repo"
echo "# p" > "$TEST_ROOT/not-a-repo/plan.md"
run_rp "$TEST_ROOT/not-a-repo" --init plan.md
assert_eq "$RP_EXIT" "2" "--init outside a git repo exits 2"

echo "Test 4: .fablepowers/.gitignore created only when absent"
setup_repo t4a
run_rp "$REPO" --init docs/plan.md
assert_eq "$(cat "$REPO/.fablepowers/.gitignore" 2>/dev/null || echo MISSING)" "*" "creates .gitignore containing '*' when absent"
setup_repo t4b
mkdir -p "$REPO/.fablepowers"
printf 'reports/\n!keep.md\n' > "$REPO/.fablepowers/.gitignore"
cp "$REPO/.fablepowers/.gitignore" "$TEST_ROOT/gitignore.orig"
run_rp "$REPO" docs/plan.md main
assert_eq "$RP_EXIT" "0" "packages with a pre-existing .gitignore"
if cmp -s "$TEST_ROOT/gitignore.orig" "$REPO/.fablepowers/.gitignore"; then
  pass "pre-existing .gitignore with different content is byte-identical after"
else
  fail "pre-existing .gitignore with different content is byte-identical after"
fi

echo "Test 5: packaging leaves git status clean"
setup_repo t5
run_rp "$REPO" docs/plan.md main
assert_eq "$RP_EXIT" "0" "packaging exits 0"
assert_eq "$(git -C "$REPO" status --porcelain)" "" "git status --porcelain is empty after packaging"

echo "Test 6: --init prints and creates the workspace"
setup_repo t6
run_rp "$REPO" --init docs/plan.md
assert_eq "$RP_EXIT" "0" "--init exits 0"
assert_eq "$RP_OUT" "$REPO/.fablepowers/plan" "--init prints <toplevel>/.fablepowers/<plan-basename>"
[ -d "$REPO/.fablepowers/plan" ] && pass "--init creates the workspace" || fail "--init creates the workspace"
run_rp "$REPO" --init docs/plan.md
assert_eq "$RP_EXIT:$RP_OUT" "0:$REPO/.fablepowers/plan" "--init is idempotent"

echo "Test 7: plan path outside the toplevel -> workspace under the cwd's toplevel"
setup_repo t7
WT="$TEST_ROOT/wt-t7"
git -C "$REPO" worktree add -q "$WT" -b wt-branch feature
echo w > "$WT/w.txt"
git -C "$WT" add w.txt
git -C "$WT" commit -q -m "worktree work"
# Plan lives in the main checkout; the command runs in the linked worktree.
run_rp "$WT" --init "$REPO/docs/plan.md"
assert_eq "$RP_OUT" "$WT/.fablepowers/plan" "--init with plan in main checkout -> workspace under the worktree"
[ ! -e "$REPO/.fablepowers" ] && pass "nothing created in the main checkout" || fail "nothing created in the main checkout"
mkdir -p "$TEST_ROOT/plans"
echo "# other" > "$TEST_ROOT/plans/other-plan.md"
run_rp "$WT" "$TEST_ROOT/plans/other-plan.md" feature
assert_eq "$RP_EXIT" "0" "packaging with a plan outside any repo exits 0"
assert_contains "$RP_OUT" "wrote $WT/.fablepowers/other-plan/review-" "package lands under the worktree's workspace"
assert_eq "$(git -C "$WT" status --porcelain)" "" "worktree git status stays clean"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All review-package tests passed."
else
  echo "$FAILURES review-package test(s) failed."
  exit 1
fi
