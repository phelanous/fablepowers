#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
# PLAN_WAVES overrides the launcher under test (used for mutation checks on a
# copy; plan_waves.py is taken from the same directory).
SCRIPT_UNDER_TEST="${PLAN_WAVES:-$REPO_ROOT/skills/subagent-execution/plan-waves}"

FAILURES=0
TEST_ROOT="$(mktemp -d)"

cleanup() {
  chmod -R u+rwX "$TEST_ROOT" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# Isolate from the user's git config (the suite runs no git, but keep the
# convention).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

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

# run_pw <args...> — runs the launcher via bash; sets PW_OUT (stdout), PW_ERR
# (stderr) and PW_EXIT; never aborts on a non-zero exit.
run_pw() {
  set +e
  PW_OUT=$(bash "$SCRIPT_UNDER_TEST" "$@" 2>"$TEST_ROOT/stderr")
  PW_EXIT=$?
  set -e
  PW_ERR=$(cat "$TEST_ROOT/stderr")
}

# expect_waves <description> <expected stdout> <args...>
expect_waves() {
  local description="$1" expected="$2"
  shift 2
  run_pw "$@"
  assert_eq "$PW_EXIT|$PW_OUT|$PW_ERR" "0|$expected|" "$description"
}

# expect_problem <description> <kind> <needle> <args...> — exit 2, empty
# stdout, and a stderr line starting `plan-waves: <kind>:` that contains
# <needle>.
expect_problem() {
  local description="$1" kind="$2" needle="$3" line found=no
  shift 3
  run_pw "$@"
  while IFS= read -r line; do
    case "$line" in
      "plan-waves: $kind:"*"$needle"*) found=yes ;;
    esac
  done <<<"$PW_ERR"
  assert_eq "$PW_EXIT|$PW_OUT|$found" "2||yes" "$description"
  [ "$found" = yes ] || echo "        stderr was: $PW_ERR"
}

# plan <name> <depends-of-T1> <depends-of-T2> <depends-of-T3> — writes a
# three-task T-style plan and prints its path. An argument of `-` leaves that
# task's Depends on line out.
plan() {
  local file="$TEST_ROOT/$1.md" i=1 dep
  shift
  printf '# Plan\n\n' >"$file"
  for dep in "$@"; do
    printf '## T%s: Task %s\n\nBody.\n\n' "$i" "$i" >>"$file"
    [ "$dep" = - ] || printf '**Depends on:** %s\n\n' "$dep" >>"$file"
    i=$((i + 1))
  done
  echo "$file"
}

WAVES3=$'wave 1: T1, T2\nwave 2: T3'
WAVES4=$'wave 1: T1, T2\nwave 2: T3\nwave 3: T4'

echo "Criterion 1: waves from the fixture plan"
expect_waves "T-style headings print three waves" "$WAVES4" "$FIXTURES/waves-t.md"
expect_waves "'## Task <n> —' headings (all four separators) print Task spellings" \
  $'wave 1: Task 1, Task 2\nwave 2: Task 3\nwave 3: Task 4' "$FIXTURES/waves-task-dash.md"
expect_waves "'### Task <n>' headings print Task spellings" \
  $'wave 1: Task 1, Task 2\nwave 2: Task 3\nwave 3: Task 4' "$FIXTURES/waves-task-h3.md"

expect_waves "'## T<n> —' headings (em dash, en dash, hyphen, spaced colon) print T spellings; '## T9 without' is no task" \
  "$WAVES4" "$FIXTURES/waves-t-dash.md"

echo "Criterion 2: Depends on spellings"
expect_waves "'nothing (spike)' and 'none (reason).' are no dependency" "$WAVES3" \
  "$(plan nothing-reason 'nothing (spike)' 'none (parallel with Task 1).' T1)"
expect_problem "'nothing (a (b))' is still malformed" bad-depends "'nothing (a (b))'" \
  "$(plan nothing-nested 'nothing (a (b))' nothing T1)"
expect_problem "'nothing yet' is still malformed" bad-depends "'nothing yet'" \
  "$(plan nothing-words 'nothing yet' nothing T1)"
expect_waves "'T1 (enum types)' — a parenthesised reason" "$WAVES3" \
  "$(plan reason nothing nothing 'T1 (enum types)')"
expect_waves "'Task 1' in a T-style plan" "$WAVES3" \
  "$(plan task-spelling nothing nothing 'Task 1')"
expect_waves "'None' (any case) is no dependency" "$WAVES3" \
  "$(plan none-case None NONE T1)"
expect_waves "a lower-case 't1' and a bare '1' name T1" "$WAVES3" \
  "$(plan bare-id nothing none 't1, 1')"
expect_waves "a single trailing period ('nothing.', 'T1 (reason).', 'T2, T3.') parses like the unpunctuated form" \
  "$WAVES4" "$FIXTURES/trailing-period.md"
expect_waves "'T2.' parses like 'T2'" $'wave 1: T1, T2\nwave 2: T3' \
  "$(plan period-id nothing nothing 'T2.')"

echo "Criterion 3: problems exit 2 and name the problem"
expect_problem "no argument" usage "plan-waves <plan-file>"
expect_problem "two arguments" usage "got 2" "$FIXTURES/waves-t.md" "$FIXTURES/waves-t.md"
expect_problem "a missing file" file "$TEST_ROOT/absent.md" "$TEST_ROOT/absent.md"
expect_problem "a directory" file "$TEST_ROOT" "$TEST_ROOT"
printf '# Notes\n\n## Goal\n\n**Depends on:** nothing\n' >"$TEST_ROOT/no-tasks.md"
expect_problem "no tasks" no-tasks "no task headings" "$TEST_ROOT/no-tasks.md"
printf '# Plan\n\n## T1: a\n\n**Depends on:** nothing\n\n## Task 1 — b\n\n**Depends on:** nothing\n' \
  >"$TEST_ROOT/duplicate.md"
expect_problem "a duplicate id (T1 and Task 1)" duplicate "T1 appears 2 times (lines 3, 7)" \
  "$TEST_ROOT/duplicate.md"
printf '# Plan\n\n## T7b: a\n\n**Depends on:** nothing\n\n## T7B: b\n\n**Depends on:** nothing\n' \
  >"$TEST_ROOT/duplicate-case.md"
expect_problem "7b and 7B are a duplicate" duplicate "T7b appears 2 times" "$TEST_ROOT/duplicate-case.md"
expect_problem "a missing Depends on line" no-depends "T2 (line 9)" "$(plan no-depends nothing - T1)"
expect_problem "two Depends on lines in one task" two-depends "T3" \
  "$(plan two-depends nothing nothing $'T1\n**Depends on:** T2')"
expect_problem "an unparseable Depends on line" bad-depends "'T1 and T2'" \
  "$(plan bad-depends nothing nothing 'T1 and T2')"
expect_problem "a value still malformed after its period is removed" bad-depends "'T1 and T2'" \
  "$(plan bad-period nothing nothing 'T1 and T2.')"
expect_problem "only one trailing period is removed ('T1..')" bad-depends "'T1.'" \
  "$(plan two-periods nothing nothing 'T1..')"
expect_problem "an empty Depends on line" bad-depends "T3" "$(plan empty-depends nothing nothing '')"
expect_problem "an unknown id" unknown-id "unknown task 8" "$(plan unknown nothing nothing 'T1, T8')"
expect_problem "a self-dependency" cycle "T3 depends on itself" "$(plan self nothing nothing T3)"
expect_problem "a two-task cycle names both members" cycle "T2, T3 depend on each other" \
  "$(plan two-cycle nothing T3 T2)"
FABLEPOWERS_PYTHON=/nonexistent expect_problem "FABLEPOWERS_PYTHON=/nonexistent" python \
  "FABLEPOWERS_PYTHON=/nonexistent" "$FIXTURES/waves-t.md"
cp "$FIXTURES/waves-t.md" "$TEST_ROOT/unreadable.md"
chmod 000 "$TEST_ROOT/unreadable.md"
if [ "$(id -u)" -eq 0 ]; then
  echo "  [SKIP] an unreadable file (running as root)"
else
  expect_problem "an unreadable file" file "cannot read" "$TEST_ROOT/unreadable.md"
fi

echo "Every problem in one run"
run_pw "$FIXTURES/three-problems.md"
assert_eq "$PW_EXIT|$PW_OUT|$(printf '%s\n' "$PW_ERR" | grep -c '^plan-waves: ')" "2||3" \
  "three distinct problems print three stderr lines"
assert_eq "$(printf '%s\n' "$PW_ERR" | sed 's/^plan-waves: \([a-z-]*\):.*/\1/' | sort | tr '\n' ' ')" \
  "duplicate no-depends unknown-id " "the three lines are duplicate, no-depends and unknown-id"
expect_problem "a cycle and a self-dependency are both reported" cycle "T1 depends on itself" \
  "$(plan cycles T1 T3 T2)"
assert_eq "$(printf '%s\n' "$PW_ERR" | grep -c '^plan-waves: cycle:')" "2" "... as two cycle lines"

echo "Criterion 4: fenced code blocks"
# Changed after re-review 1 (R2): a column-0 task heading or Depends on line
# inside a fence is reported, not ignored; other fenced lines are still skipped.
expect_waves "fenced lines that are no column-0 heading or Depends on line are skipped" \
  $'wave 1: T1\nwave 2: T2' "$FIXTURES/fence-quoted.md"
expect_problem "a heading and a Depends on line inside a closed fence are heading-in-fence" heading-in-fence \
  "opened at line 7 and closed at line 10 holds T9 (line 8), **Depends on:** (line 9)" "$FIXTURES/fences.md"
expect_problem "... and a fenced Depends on line alone is too" heading-in-fence \
  "opened at line 20 and closed at line 22 holds **Depends on:** (line 21)" "$FIXTURES/fences.md"
expect_problem "a \`\`\`\` fence is not closed by \`\`\`, so its '## T9:' is fenced" heading-in-fence \
  "opened at line 9 and closed at line 13 holds T9 (line 11)" "$FIXTURES/fence-nested.md"
expect_problem "a \`\`\` fence is not closed by ~~~, so its '## T9:' is fenced" heading-in-fence \
  "opened at line 19 and closed at line 23 holds T9 (line 21)" "$FIXTURES/fence-nested.md"

echo "Unclosed fences (integration review S4)"
expect_problem "an unclosed \`\`\`python fence before a task heading is reported" unclosed-fence \
  "line 7 is never closed, hiding task heading(s) T2 (line 10)" "$FIXTURES/unclosed-fence.md"
expect_problem "an unclosed 4-space-indented fence before a task heading is reported" unclosed-fence \
  "line 9 is never closed, hiding task heading(s) T2 (line 12)" "$FIXTURES/unclosed-fence-indented.md"
expect_waves "an unclosed fence with no task heading after it is not a problem" \
  $'wave 1: T1\nwave 2: T2' "$FIXTURES/unclosed-fence-trailing.md"

echo "A fence left open that pairs with a later closer (re-review 1, R2)"
expect_problem "an open \`\`\`python closed by a later block's \`\`\` reports the tasks it swallowed" heading-in-fence \
  "opened at line 16 and closed at line 31 holds **Depends on:** (line 19), T2 (line 22), **Depends on:** (line 24), T3 (line 27)" \
  "$FIXTURES/fence-paired.md"
assert_eq "$(printf '%s\n' "$PW_ERR" | grep -c '^plan-waves: ')" "1" "... as one problem line"

echo "Plan format (integration review M1)"
# expect_format <description> <expected> <plan>
expect_format() {
  run_pw --format "$3"
  assert_eq "$PW_EXIT|$PW_OUT|$PW_ERR" "0|$2|" "$1"
}
# The fixture has Depends on lines that plan-waves rejects and no Touches line
# or Parallel safety section, like most real plans written before 0.8.0.
run_pw "$FIXTURES/pre-080-depends.md"
assert_eq "$PW_EXIT" "2" "the pre-0.8.0 fixture's Depends on lines fail plan-waves"
if grep -qF '**Depends on:**' "$FIXTURES/pre-080-depends.md"; then
  pass "... and the 0.8.0-era key (no **Depends on:** line at all) would not have called it pre-0.8.0"
else
  fail "the fixture has no **Depends on:** line, so it does not reproduce the misclassification"
fi
expect_format "a plan with Depends on lines but no Touches line or Parallel safety heading is pre-0.8.0" \
  pre-0.8.0 "$FIXTURES/pre-080-depends.md"
printf '# Plan\n\n## T1: a\n\nBody.\n' >"$TEST_ROOT/no-lines.md"
expect_format "a plan with neither line is pre-0.8.0" pre-0.8.0 "$TEST_ROOT/no-lines.md"
expect_format "a plan with both is 0.8.0" 0.8.0 "$FIXTURES/waves-t.md"
printf '# Plan\n\n## T1: a\n\n**Depends on:** nothing\n- **Touches:** none\n' >"$TEST_ROOT/touches-only.md"
expect_format "a (bulleted) Touches line alone makes it 0.8.0" 0.8.0 "$TEST_ROOT/touches-only.md"
printf '# Plan\n\n### parallel Safety\n\nNone.\n\n## T1: a\n' >"$TEST_ROOT/safety-only.md"
expect_format "a Parallel safety heading alone (any level, any case) makes it 0.8.0" 0.8.0 \
  "$TEST_ROOT/safety-only.md"
# Changed after re-review 1 (R3): fences are not consulted, so a 0.8.0 plan
# whose markers a broken fence swallowed still reaches the wave script.
expect_format "Touches and Parallel safety swallowed by a fence left open still make it 0.8.0" 0.8.0 \
  "$FIXTURES/fence-open-markers.md"
expect_problem "... and the wave script then reports the fence" unclosed-fence \
  "line 5 is never closed, hiding task heading(s) T1 (line 12), T2 (line 17)" "$FIXTURES/fence-open-markers.md"
printf '# Plan\n\n## T1: a\n\n**Depends on:** nothing\n\n```markdown\n  **Touches:** none\n```\n' >"$TEST_ROOT/fenced-touches.md"
expect_format "a Touches line inside a closed fence also counts (the trade-off)" 0.8.0 "$TEST_ROOT/fenced-touches.md"
expect_problem "--format with no plan" usage "got 0 arguments" --format
expect_problem "--format with a missing file" file "$TEST_ROOT/absent.md" --format "$TEST_ROOT/absent.md"

echo "Line endings and indentation"
for f in waves-t fences fence-nested trailing-period; do
  sed 's/$/\r/' "$FIXTURES/$f.md" >"$TEST_ROOT/$f-crlf.md"
  run_pw "$FIXTURES/$f.md"
  lf="$PW_EXIT|$PW_OUT|$PW_ERR"
  run_pw "$TEST_ROOT/$f-crlf.md"
  assert_eq "$PW_EXIT|$PW_OUT|$PW_ERR" "$lf" "a CRLF copy of $f.md gives identical output"
done
expect_waves "an indented '  ## T9:' line is not a task" "$WAVES3" "$FIXTURES/indented.md"

echo "Never writes files"
cp -R "$(dirname "$SCRIPT_UNDER_TEST")" "$TEST_ROOT/copy"
cp "$FIXTURES/waves-t.md" "$TEST_ROOT/copy/plan.md"
before=$(cd "$TEST_ROOT/copy" && find . | sort)
(cd "$TEST_ROOT/copy" && bash ./plan-waves plan.md >/dev/null 2>&1 && bash ./plan-waves >/dev/null 2>&1) || true
assert_eq "$(cd "$TEST_ROOT/copy" && find . | sort)" "$before" "a run leaves the script and plan directories unchanged"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All plan-waves tests passed."
else
  echo "$FAILURES plan-waves test(s) failed."
fi
exit "$FAILURES"
