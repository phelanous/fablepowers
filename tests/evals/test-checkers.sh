#!/usr/bin/env bash
# Offline tests for the live-eval checkers (tests/evals/fixtures/<eval>/check.py).
# Each checker runs on the synthetic fixtures under checker-fixtures/<eval>/:
# it must pass the `pass` case and fail each doctored case on exactly the
# assertions that case names in its `expect` file (one per line; every
# assertion also has a case naming it alone). Needs no claude login.
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

# An expect file holds `pass` or assertion names, one per line; several only
# for a replay that goes wrong in several ways at once. A case matches when a
# pass exits 0 failing nothing, or a doctored case exits 1 failing exactly
# the named set.
expect_set() {
  grep -v '^[[:space:]]*$' "$1" | tr -d '[:blank:]' | sort | paste -sd' ' -
}
failed_set() {
  printf '%s\n' "$1" | sed -n 's/^  \[FAIL\] \([^ ]*\).*/\1/p' | sort | paste -sd' ' -
}
outcome_ok() { # <expect set> <exit status> <failed set>
  if [[ "$1" == pass ]]; then [[ $2 -eq 0 && -z "$3" ]]; else [[ $2 -eq 1 && "$3" == "$1" ]]; fi
}

echo "Test 1: the committed checker fixtures match build.py"
if out="$("$PY" -I "$CASES/build.py" --check 2>&1)"; then
  pass "$out"
else
  fail "$out"
fi

echo "Test 2: each checker passes its pass case and fails each doctored case on exactly the assertions it names"
for evdir in "$CASES"/*/; do
  ev="$(basename "$evdir")"
  for case in "$evdir"*/; do
    case="${case%/}"
    name="$(basename "$case")"
    rc=0
    out="$("$PY" -I "$CHECKERS/$ev/check.py" "$case/session.jsonl" "$case" 2>&1)" || rc=$?
    expect="$(expect_set "$case/expect")"
    failed="$(failed_set "$out")"
    if outcome_ok "$expect" "$rc" "$failed"; then
      if [[ "$expect" == pass ]]; then pass "$ev/$name: passes"; else pass "$ev/$name: fails only $expect"; fi
    else
      fail "$ev/$name: expected ${expect/#pass/a pass}, got exit $rc failing ${failed:-nothing}:"$'\n'"$out"
    fi
  done
done

echo "Test 3: every assertion a checker prints has a doctored case failing it alone"
for evdir in "$CASES"/*/; do
  ev="$(basename "$evdir")"
  names="$("$PY" -I "$CHECKERS/$ev/check.py" "$evdir/pass/session.jsonl" "$evdir/pass" 2>/dev/null \
    | sed -n 's/^  \[PASS\] \([^ ]*\).*/\1/p' || true)"
  if [[ -z "$names" ]]; then
    fail "$ev: the pass case printed no assertions"
    continue
  fi
  for n in $names; do
    alone=no
    for e in "$evdir"*/expect; do
      if [[ "$(grep -v '^[[:space:]]*$' "$e" | tr -d '[:blank:]')" == "$n" ]]; then alone=yes; break; fi
    done
    if [[ $alone == yes ]]; then
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
expect_waves eval11 'wave 1: T1, T2'
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
# CLAUDE_BIN=false: should the check ever let the run through, nothing is billed.
rc=0
out="$(EVAL_PLUGIN_DIR="$TEST_ROOT/no-such-plugin" CLAUDE_BIN=false bash "$SCRIPT_DIR/run-eval.sh" eval11 2>&1)" || rc=$?
if [[ $rc -eq 2 && "$out" == *"EVAL_PLUGIN_DIR"* ]]; then
  pass "EVAL_PLUGIN_DIR without a plugin manifest: exit 2 before any run"
else
  fail "EVAL_PLUGIN_DIR without a plugin manifest: exit $rc, expected 2:"$'\n'"$out"
fi
# A stand-in claude that records its arguments: no live run, nothing billed.
mkdir -p "$TEST_ROOT/plugin/.claude-plugin" "$TEST_ROOT/fake-out"
printf '{"name": "fablepowers"}\n' > "$TEST_ROOT/plugin/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/claude-args.txt"\n' "$TEST_ROOT" > "$TEST_ROOT/fake-claude"
chmod +x "$TEST_ROOT/fake-claude"
for plug in "$TEST_ROOT/plugin" ""; do
  rm -f "$TEST_ROOT/claude-args.txt"
  out="$(EVAL_PLUGIN_DIR="$plug" CLAUDE_BIN="$TEST_ROOT/fake-claude" EVAL_OUT="$TEST_ROOT/fake-out" \
    bash "$SCRIPT_DIR/run-eval.sh" eval11-clean 2>&1)" || true
  kept="$(printf '%s\n' "$out" | sed -n 's/^kept: //p')"
  if [[ -n "$kept" && -d "$kept" && "$(basename "$kept")" == tmp.* ]]; then rm -rf "$kept"; fi
  got="$(sed -n '/^--plugin-dir$/{n;p;}' "$TEST_ROOT/claude-args.txt" 2>/dev/null)"
  want="${plug:-$REPO_ROOT}"
  if [[ "$got" == "$want" ]]; then
    pass "EVAL_PLUGIN_DIR=${plug:-(unset)}: --plugin-dir $(basename "$got")"
  else
    fail "EVAL_PLUGIN_DIR=${plug:-(unset)}: --plugin-dir '$got', expected '$want':"$'\n'"$out"
  fi
done

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

echo "Test 9: the eval11 and eval12 setup scripts build the states their checkers assume"
# As run-eval.sh does: the seed committed on main as "init", then setup.sh.
build_state() {
  local ev="$1" dir="$TEST_ROOT/state-$1" seed
  seed="$SCRIPT_DIR/fixtures/$ev/seed"
  [[ -d "$seed" ]] || seed="$SCRIPT_DIR/fixtures/$(tr -d '[:space:]' < "$SCRIPT_DIR/fixtures/$ev/seed-from")/seed"
  mkdir -p "$dir/repo" "$dir/out"
  cp -a "$seed/." "$dir/repo/"
  git -C "$dir/repo" init -q -b main
  git -C "$dir/repo" config user.name Eval
  git -C "$dir/repo" config user.email eval@example.invalid
  git -C "$dir/repo" config commit.gpgsign false
  git -C "$dir/repo" add -A
  git -C "$dir/repo" commit -qm init
  (cd "$dir/repo" && PLUGIN_ROOT="$REPO_ROOT" OUT="$dir/out" FIXTURE="$SCRIPT_DIR/fixtures/$ev" \
    bash "$SCRIPT_DIR/fixtures/$ev/setup.sh") >/dev/null 2>&1
}
state_check() { # <name> <condition result 0/1> <detail>
  if [[ "$2" == 0 ]]; then pass "$1"; else fail "$1: $3"; fi
}
for ev in eval11 eval11-clean eval11-rebase eval12 eval12-c2; do
  if ! build_state "$ev"; then
    fail "$ev: setup.sh failed"
    continue
  fi
  R="$TEST_ROOT/state-$ev/repo"
  O="$TEST_ROOT/state-$ev/out"
  G() { git -C "$R" "$@"; }
  led="$R/.fablepowers/demo/progress.md"
  rh="$(cat "$O/reviewed-head.txt" 2>/dev/null || true)"
  last_review="$(grep '^review ' "$led" | tail -n 1 | cut -d'|' -f2 | tr -d ' ')"
  rc=1; [[ "$(G branch --show-current)" == feat/demo && -z "$(G status --porcelain)" ]] && rc=0
  state_check "$ev: feat/demo checked out, clean tree" "$rc" "$(G branch --show-current) / $(G status --porcelain)"
  rc=1; [[ -n "$rh" && "$(G rev-parse --short=7 "$rh")" == "$last_review" ]] && rc=0
  state_check "$ev: reviewed-head.txt is the latest review line's SHA ($last_review)" "$rc" "file $rh"
  rc=0; (cd "$R" && bash tests/run-all.sh >/dev/null 2>&1) || rc=1
  state_check "$ev: the fixture's suite passes" "$rc" "tests/run-all.sh failed"
  mb="$(G merge-base HEAD main)"
  case "$ev" in
    eval11|eval11-clean)
      after="$(G rev-list --count "$rh..HEAD")"
      want=1; [[ "$ev" == eval11 ]] && want=2
      rc=1; G merge-base --is-ancestor "$rh" HEAD && [[ "$after" == "$want" && "$rh" != "$mb" ]] \
        && [[ "$(G log -1 --format=%s)" == "feat: neg" ]] && rc=0
      state_check "$ev: $want commit(s) past the reviewed head, the last one feat: neg" "$rc" "$after past it, HEAD '$(G log -1 --format=%s)'"
      if [[ "$ev" == eval11 ]]; then
        got="$(grep -E '^(review|fix) ' "$led" | cut -d'|' -f1 | sed 's/ *$//' | paste -sd, -)"
        want_l="review integration,fix integration-1,review rereview-1,fix integration-2,review rereview-2,fix integration-3"
        rc=1; [[ "$got" == "$want_l" ]] && rc=0
        state_check "$ev: cycle 1 capped in the ledger" "$rc" "$got"
      else
        rc=1; [[ "$(grep -cE '^(review|fix) ' "$led")" == 1 ]] && grep -q '^review integration |.*| 0 must-fix |' "$led" && rc=0
        state_check "$ev: cycle 1 ended clean, no re-review" "$rc" "$(grep -E '^(review|fix) ' "$led")"
      fi
      ;;
    eval11-rebase)
      img="$(cat "$O/reviewed-image.txt" 2>/dev/null || true)"
      rc=1; [[ "$(G cat-file -t "$rh" 2>/dev/null)" == commit ]] && ! G merge-base --is-ancestor "$rh" HEAD && rc=0
      state_check "$ev: the reviewed head exists and is not an ancestor of HEAD" "$rc" "$rh"
      old_mb="$(G merge-base "$rh" main)"
      n="$(G rev-list --count "$old_mb..$rh")"
      rd="$(G range-diff "$old_mb..$rh" "$mb..$(G rev-list --reverse "$mb..HEAD" | sed -n "${n}p")")"
      rc=1; [[ -n "$rd" ]] && ! printf '%s\n' "$rd" | grep -qvE '^[0-9]+: +[0-9a-f]+ = ' && rc=0
      state_check "$ev: range-diff pairs all $n commits with =" "$rc" "$rd"
      rc=1; [[ -n "$img" && "$img" == "$(G rev-parse HEAD)" && "$(G rev-list --count main)" == 2 ]] && rc=0
      state_check "$ev: reviewed-image.txt is HEAD; main moved one commit" "$rc" "image $img, HEAD $(G rev-parse HEAD)"
      ;;
    eval12|eval12-c2)
      kinds="$(grep -E '^(review|fix) ' "$led" | cut -d'|' -f1 | sed 's/ *$//' | paste -sd, -)"
      want_l="review integration,fix integration-1,review rereview-1,fix integration-2,review rereview-2,fix integration-3"
      [[ "$ev" == eval12-c2 ]] && want_l="$want_l,review integration-c2,fix integration-c2-1"
      rc=1; [[ "$kinds" == "$want_l" ]] && rc=0
      state_check "$ev: the ledger ends with its owed fix line" "$rc" "$kinds"
      last="$(grep -E '^(review|fix) ' "$led" | tail -n 1)"
      rc=1; [[ "$(printf '%s' "$last" | cut -d'|' -f2 | tr -d ' ')" == "$(G rev-parse --short=7 HEAD)" ]] \
        && [[ "$(G rev-list --count "$rh..HEAD")" == 1 ]] && G merge-base --is-ancestor "$rh" HEAD && rc=0
      state_check "$ev: one commit past the reviewed head, the last fix line's, at HEAD" "$rc" "$last / HEAD $(G rev-parse --short=7 HEAD)"
      if [[ "$ev" == eval12 ]]; then
        rc=1; [[ "$(G log -1 --format=%s)" == "docs: mul returns the product" ]] \
          && ! grep -qi 'verify-done\|capped' "$R/.fablepowers/demo/reports/integration-fix3.md" && rc=0
        state_check "$ev: fix 3 at HEAD, its report not yet verified or capped" "$rc" "$(G log -1 --format=%s)"
      else
        rc=1; [[ "$(G log -1 --format=%s "$rh")" == "feat: neg" ]] \
          && G show "$rh:mathx/neg.py" | grep -q 'return -abs(x)$' && G show HEAD:mathx/neg.py | grep -q 'return -x$' \
          && [[ -s "$R/.fablepowers/demo/reports/review-integration-c2.md" && -s "$R/.fablepowers/demo/reports/integration-fix-c2-1.md" ]] && rc=0
        state_check "$ev: the cycle-2 head is feat: neg with the must-fix bug; both cycle-2 reports seeded" "$rc" "$(G log -1 --format=%s "$rh")"
      fi
      ;;
  esac
done

echo "Test 10: the review-cycle helpers read ledgers, package paths and integration commands"
rc=0
out="$("$PY" -I - "${EVAL_LIB:-$SCRIPT_DIR/lib}" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import evalcheck as ec

def say(ok, what):
    print("%s %s" % ("ok" if ok else "bad", what))

for seg, want in [("git merge --no-ff --no-edit feat/demo", "merge"),
                  ("git -C /r merge feat/demo", "merge"),
                  ("git --no-pager merge --ff-only feat/demo", "merge"),
                  ("git merge-base main HEAD", None),
                  ("git merge-base --is-ancestor c0ffee1 HEAD", None),
                  ("git merge-tree main feat/demo", None),
                  ("git merge --abort", None),
                  ("git push -u origin feat/demo", "push"),
                  ("git push origin HEAD:refs/for/main -o topic=x", "push"),
                  ("gh pr create --base main", "pr"),
                  ("fj pr create 'Title' --head feat/demo --base main", "pr"),
                  ("git log --oneline main..HEAD", None),
                  ("git commit -m 'merge notes; push later'", None)]:
    got = ec.integration_kind(seg)
    say(got == want, "integration_kind(%r) is %s" % (seg, got))
for text, want in [("Package: /w/review-c0ffee1..abc1299.diff", [("c0ffee1", "abc1299")]),
                   ("no package here", [])]:
    got = ec.package_ranges(text)
    say(got == want, "package_ranges finds %s" % (got or "none"))
for a, b, want in [("c0ffee1", "c0ffee12222", True), ("c0ffee1222", "c0ffee1333", False),
                   ("c0ffee", "c0ffee1", False), ("", "c0ffee1", False)]:
    say(ec.same_sha(a, b) == want, "same_sha(%r, %r) is %s" % (a, b, want))

class S:
    def __init__(self, text):
        self.text = text
    def progress(self):
        return self.text

s = S("# Progress: docs/plans/demo.md\ntask 1 | abc1201 | DONE | reports/task-1.md\n"
      "review integration | abc1202 | 0 must-fix | reports/review-integration.md\n"
      "review integration-c2 | abc1299 | 0 must-fix | /r/.fablepowers/demo/reports/review-integration-c2.md\n"
      "review carried | abc1203 | patch-identical | —\n")
ids = [e.id for e in ec.review_entries(s)]
say(ids == ["integration", "integration-c2", "carried"], "review_entries ids %s" % ids)
c2 = ec.review_entries(s, "integration-c2")
say(len(c2) == 1 and ec.report_is(c2[0], "reports/review-integration-c2.md"), "an absolute workspace report path counts")
say(not ec.report_is(ec.Entry("", "review", "integration-c2", "x", "v", ".worktrees/t/reports/review-integration-c2.md"),
                     "reports/review-integration-c2.md"), "a task-worktree report path does not")
carried = ec.review_entries(s, "carried")[0]
say(carried.sha == "abc1203" and carried.verdict == "patch-identical" and ec.no_report(carried), "carried line fields")
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

echo "Test 11: a case matches only on exactly the assertions its expect file names"
printf 'b\n\na\n' > "$TEST_ROOT/expect-ab"
ab="$(expect_set "$TEST_ROOT/expect-ab")"
two="$(failed_set $'  [FAIL] b — x\n  [PASS] c\n  [FAIL] a — y')"
for row in "pass|0||yes" "pass|1|a|no" "pass|0|a|no" "a|1|a|yes" "a|1|b|no" "a|0||no" "a|1|a b|no" "$ab|1|$two|yes" "$ab|1|a|no"; do
  IFS='|' read -r e st fl want <<<"$row"
  got=no; outcome_ok "$e" "$st" "$fl" && got=yes
  if [[ "$got" == "$want" ]]; then pass "expect '$e', exit $st, failing '${fl:-nothing}': match $got"
  else fail "expect '$e', exit $st, failing '${fl:-nothing}': match $got, wanted $want"; fi
done

echo "Test 12: the cycle helpers count each cycle's re-reviews from its own opening line"
rc=0
out="$("$PY" -I - "${EVAL_LIB:-$SCRIPT_DIR/lib}" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import evalcheck as ec

def say(ok, what):
    print("%s %s" % ("ok" if ok else "bad", what))

class S:
    def __init__(self, lines):
        self.text = "# Progress: docs/plans/demo.md\n" + "".join(l + "\n" for l in lines)
    def progress(self):
        return self.text

def L(kind_id, sha="abc1201", verdict="0 must-fix", report="—"):
    return "%s | %s | %s | %s" % (kind_id, sha, verdict, report)

c1 = [L("task 1"), L("review integration", verdict="1 must-fix"), L("fix integration-1"), L("review rereview-1"),
      L("fix integration-2"), L("review rereview-2"), L("fix integration-3")]
rows = [
    ("no review line: no cycle", [L("task 1")], None),
    ("a re-review before any integration line belongs to no cycle", [L("review rereview-1")], None),
    ("cycle 1 with two re-reviews is capped", c1, (1, "integration", 2, True)),
    ("one re-review is not capped", c1[:4], (1, "integration", 1, False)),
    ("three re-reviews in one cycle read as capped", c1 + [L("review rereview-3")], (1, "integration", 3, True)),
    ("integration-c2 opens cycle 2 with its own count", c1 + [L("review integration-c2")], (2, "integration-c2", 0, False)),
    ("rereview-c2-1 counts against cycle 2", c1 + [L("review integration-c2"), L("review rereview-c2-1")],
     (2, "integration-c2", 1, False)),
    ("review carried opens nothing", c1 + [L("review carried", verdict="patch-identical")], (1, "integration", 2, True)),
    ("the cycle number is the count of opening lines, whatever the id", [L("review integration"), L("review integration-c3")],
     (2, "integration-c3", 0, False)),
]
for name, lines, want in rows:
    cur = ec.current_cycle(S(lines))
    got = (cur.number, cur.opening.id, cur.used, cur.capped) if cur else None
    say(got == want, "%s: %s" % (name, got))
say([c.used for c in ec.review_cycles(S(c1 + [L("review integration-c2"), L("review rereview-c2-1")]))] == [2, 1],
    "review_cycles keeps each cycle's own count")
for text, want in [("The review loop was capped after re-review 2.", True),
                   ("the re-review cap of cycle 1 was reached", True),
                   ("the cap of two re-reviews is used", True),
                   ("We hit the\nre-review cap.", True),
                   ("Ready to merge; the suite passes.", False),
                   ("capability check passed; recap below", False),
                   ("no cap applies here", False)]:
    say(ec.says_capped(text) == want, "says_capped(%r) is %s" % (text, want))
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

echo
if [[ $FAILURES -eq 0 ]]; then
  echo "All eval checker tests passed."
else
  echo "$FAILURES eval checker test(s) failed."
fi
exit "$FAILURES"
