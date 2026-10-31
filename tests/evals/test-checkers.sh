#!/usr/bin/env bash
# Offline tests for the live-eval checkers (tests/evals/fixtures/<eval>/check.py).
# Each checker runs on the synthetic fixtures under checker-fixtures/<eval>/:
# it must pass the `pass` case and fail each doctored case on exactly the one
# assertion that case names in its `expect` file. Needs no claude login.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# EVAL_CHECKERS overrides the directory holding <eval>/check.py (used for
# mutation checks on a copy; the copy needs ../../lib beside it).
CHECKERS="${EVAL_CHECKERS:-$SCRIPT_DIR/fixtures}"
CASES="$SCRIPT_DIR/checker-fixtures"

FAILURES=0
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# Isolate from the user's git config (signing, hooks, default branch names).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PYTHONDONTWRITEBYTECODE=1

pass() {
  echo "  [PASS] $1"
}

fail() {
  echo "  [FAIL] $1"
  FAILURES=$((FAILURES + 1))
}

# Interpreter search mirrors hooks/approval-gate.
usable() {
  [[ -n "$1" && -f "$1" && -x "$1" ]] \
    && "$1" -I -c 'import sys; sys.exit(sys.version_info < (3, 8))' </dev/null >/dev/null 2>&1
}
if [[ -n "${FABLEPOWERS_PYTHON:-}" ]]; then
  candidates=("$FABLEPOWERS_PYTHON")
else
  candidates=()
  p="$(command -v python3 2>/dev/null)" && candidates+=("$p")
  candidates+=(/usr/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3)
fi
PY=""
for c in "${candidates[@]}"; do
  if usable "$c"; then PY="$c"; break; fi
done
if [[ -z "$PY" ]]; then
  echo "python3 >= 3.8 not found" >&2
  exit 1
fi

echo "Test 1: the committed checker fixtures match build.py"
if out="$("$PY" -I "$CASES/build.py" --check 2>&1)"; then
  pass "$out"
else
  fail "$out"
fi

echo "Test 2: each checker passes its pass case and fails each doctored case on its one assertion"
for evdir in "$CASES"/*/; do
  ev="$(basename "$evdir")"
  for case in "$evdir"*/; do
    case="${case%/}"
    name="$(basename "$case")"
    expect="$(tr -d '[:space:]' < "$case/expect")"
    rc=0
    out="$("$PY" -I "$CHECKERS/$ev/check.py" "$case/session.jsonl" "$case" 2>&1)" || rc=$?
    fails="$(printf '%s\n' "$out" | grep -c '^  \[FAIL\]' || true)"
    if [[ "$expect" == pass ]]; then
      if [[ $rc -eq 0 && $fails -eq 0 ]]; then
        pass "$ev/$name: passes"
      else
        fail "$ev/$name: expected a pass, got exit $rc with $fails failure(s):"$'\n'"$out"
      fi
    else
      if [[ $rc -eq 1 && $fails -eq 1 ]] && printf '%s\n' "$out" | grep -q "^  \[FAIL\] $expect\( \|$\)"; then
        pass "$ev/$name: fails only $expect"
      else
        fail "$ev/$name: expected exit 1 failing only $expect, got exit $rc with $fails failure(s):"$'\n'"$out"
      fi
    fi
  done
done

echo "Test 3: every assertion a checker prints has a doctored case"
for evdir in "$CASES"/*/; do
  ev="$(basename "$evdir")"
  names="$("$PY" -I "$CHECKERS/$ev/check.py" "$evdir/pass/session.jsonl" "$evdir/pass" 2>/dev/null \
    | sed -n 's/^  \[PASS\] \([^ ]*\).*/\1/p' || true)"
  if [[ -z "$names" ]]; then
    fail "$ev: the pass case printed no assertions"
    continue
  fi
  for n in $names; do
    if grep -qxF "$n" "$evdir"/*/expect; then
      pass "$ev: $n has a doctored case"
    else
      fail "$ev: $n has no doctored case"
    fi
  done
done

echo "Test 4: checkers reject a wrong argument count"
rc=0
"$PY" -I "$CHECKERS/eval6/check.py" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then pass "no arguments: exit 2"; else fail "no arguments: exit $rc, expected 2"; fi

echo "Test 5: the fixture plans give the waves each eval relies on"
WAVES="$REPO_ROOT/skills/subagent-execution/plan-waves"
expect_waves() {
  local ev="$1" want="$2" rc=0 got
  got="$(bash "$WAVES" "$SCRIPT_DIR/fixtures/$ev/seed/docs/plans/demo.md" 2>&1)" || rc=$?
  if [[ $rc -eq 0 && "$got" == "$want" ]]; then
    pass "$ev: $(printf '%s' "$got" | tr '\n' ' ')"
  else
    fail "$ev: exit $rc, got: $got"
  fi
}
expect_waves eval6 $'wave 1: T1, T2\nwave 2: T3'
expect_waves eval7 'wave 1: T1, T2'
expect_waves eval8 'wave 1: T1, T2, T3'
expect_waves eval9 'wave 1: T1'
rc=0
got="$(bash "$WAVES" "$SCRIPT_DIR/fixtures/eval10/seed/docs/plans/demo.md" 2>&1)" || rc=$?
if [[ $rc -eq 2 && "$got" == *"plan-waves: no-depends: T3"* ]]; then
  pass "eval10: plan-waves reports T3's missing Depends on line"
else
  fail "eval10: exit $rc, got: $got"
fi

echo "Test 6: run-eval.sh checks without a live run, and rejects bad arguments"
rc=0
bash "$SCRIPT_DIR/run-eval.sh" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then pass "no eval name: exit 2"; else fail "no eval name: exit $rc, expected 2"; fi
rc=0
bash "$SCRIPT_DIR/run-eval.sh" no-such-eval >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then pass "unknown eval: exit 2"; else fail "unknown eval: exit $rc, expected 2"; fi
rc=0
out="$(EVAL_RECHECK="$CASES/eval8/pass" bash "$SCRIPT_DIR/run-eval.sh" eval8 2>&1)" || rc=$?
if [[ $rc -eq 0 && "$out" == *"cost_usd=1.5"* ]]; then
  pass "recheck of a passing output: exit 0, cost printed"
else
  fail "recheck of a passing output: exit $rc:"$'\n'"$out"
fi
rc=0
EVAL_RECHECK="$CASES/eval8/overlap" bash "$SCRIPT_DIR/run-eval.sh" eval8 >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 1 ]]; then pass "recheck of a failing output: exit 1"; else fail "recheck of a failing output: exit $rc, expected 1"; fi

echo "Test 7: the shared helpers read both task-id spellings and per-task fix-round ledger lines"
# EVAL_LIB overrides the helper library (mutation checks on a copy).
rc=0
out="$("$PY" -I - "${EVAL_LIB:-$SCRIPT_DIR/lib}" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import evalcheck as ec

def call(prompt):
    return ec.Call(0, {"name": "Agent", "input": {"prompt": prompt, "subagent_type": "fablepowers:implementer"}}, "", "m")

cases = [
    ("Report: /w/reports/task-1.md", ("task", "1")),
    ("Report: /w/reports/task-T1.md", ("task", "1")),
    ("Report: /w/reports/task-2-fix1.md", ("fix", "2")),
    ("Report: /w/reports/task-T2-fix1.md", ("fix", "2")),
    ("Report: /w/reports/task-7b-merge2.md", ("merge", "7b")),
    ("Report: /w/reports/task-T7b-merge2.md", ("merge", "7b")),
]
for prompt, want in cases:
    got = ec.classify_dispatch(call(prompt))
    print("%s %s classifies as %s" % ("ok" if got == want else "bad", prompt.split("/")[-1], got))
lines = [("fix 2-1 | abc1234 | DONE | reports/task-2-fix1.md", True),
         ("fix T2-1 | abc1234 | DONE | reports/task-T2-fix1.md", True),
         ("fix integration-1 | abc1234 | DONE | reports/integration-fix1.md", False),
         ("merge 2-1 | abc1234 | DONE | reports/task-2-merge1.md", False),
         ("fix 22-1 | abc1234 | DONE | reports/task-22-fix1.md", False)]
for line, want in lines:
    got = bool(ec.round_re("fix", "2").match(line))
    print("%s round_re('fix', '2') on %r: %s" % ("ok" if got == want else "bad", line.split(" |")[0], got))
PYEOF
)" || rc=$?
if [[ $rc -ne 0 ]]; then
  fail "the helper checks exited $rc:"$'\n'"$out"
else
  while IFS= read -r line; do
    case "$line" in
      ok\ *) pass "${line#ok }" ;;
      *) fail "${line#bad }" ;;
    esac
  done <<<"$out"
fi

echo "Test 8: the pre-commit suite rule holds with two serialize run resources (re-review 1, R1)"
# The reviewer's scenario: e2e (fixed port 4500) and test-db (one shared
# schema), both serialize; T1 Touches e2e, T2 Touches test-db, T3 none, all
# in flight together. Under af5f1ea's rule a task touching a serialize run
# resource ran the full suite, so T1 used test-db and T2 used port 4500 while
# the other held them. Under the rule now, each runs the pre-commit suite
# plus only its own resources' parts.
rc=0
out="$("$PY" -I - "${EVAL_LIB:-$SCRIPT_DIR/lib}" 2>&1 <<'PYEOF'
import re
import sys
sys.path.insert(0, sys.argv[1])
import evalcheck as ec

parts = {"e2e": re.compile(r"tests/e2e\.sh"), "test-db": re.compile(r"tests/db\.sh")}
full = re.compile(r"tests/run-all\.sh")
pre = "cd /w && python3 -m pytest -m 'not e2e and not db'"
cases = [
    ("af5f1ea's rule: T1 (Touches e2e) runs the full suite", ["cd /w && bash tests/run-all.sh"], {"e2e"}, ["test-db"]),
    ("af5f1ea's rule: T2 (Touches test-db) runs the full suite", ["cd /w && bash tests/run-all.sh"], {"test-db"}, ["e2e"]),
    ("new rule: T1 runs the pre-commit suite and the e2e part", [pre, "cd /w && bash tests/e2e.sh"], {"e2e"}, []),
    ("new rule: T2 runs the pre-commit suite and the test-db part", [pre, "cd /w && bash tests/db.sh"], {"test-db"}, []),
    ("new rule: T3 (Touches none) runs the pre-commit suite only", [pre], set(), []),
    ("T1 running the test-db part it doesn't hold", [pre, "cd /w && bash tests/e2e.sh", "cd /w && bash tests/db.sh"], {"e2e"}, ["test-db"]),
    ("a task holding both may run the full suite", ["cd /w && bash tests/run-all.sh"], {"e2e", "test-db"}, []),
]
for name, runs, held, want in cases:
    got = [res for res, _ in ec.unheld_parts(runs, parts, full, held)]
    print("%s %s: unheld %s" % ("ok" if got == want else "bad", name, got or "none"))
PYEOF
)" || rc=$?
if [[ $rc -ne 0 ]]; then
  fail "the rule checks exited $rc:"$'\n'"$out"
else
  while IFS= read -r line; do
    case "$line" in
      ok\ *) pass "${line#ok }" ;;
      *) fail "${line#bad }" ;;
    esac
  done <<<"$out"
fi

echo
if [[ $FAILURES -eq 0 ]]; then
  echo "All eval checker tests passed."
else
  echo "$FAILURES eval checker test(s) failed."
fi
exit "$FAILURES"
