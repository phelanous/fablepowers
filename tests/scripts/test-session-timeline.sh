#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# SESSION_TIMELINE overrides the script under test (used for mutation checks on a copy).
SCRIPT_UNDER_TEST="${SESSION_TIMELINE:-$REPO_ROOT/scripts/session-timeline.py}"
FIX="$SCRIPT_DIR/fixtures/session-timeline"

FAILURES=0
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# Isolate from the user's git config (signing, hooks, default branch names).
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

assert_contains() {
  local haystack="$1" needle="$2" description="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    pass "$description"
  else
    fail "$description (expected to contain: $needle)"
  fi
}

# Interpreter search mirrors hooks/approval-gate: $FABLEPOWERS_PYTHON alone when
# set, else python3 on PATH, then the usual absolute paths; first one >= 3.8.
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
  echo "no usable python3 (>= 3.8) found" >&2
  exit 1
fi

# run_st <args...> — sets ST_OUT (stdout), ST_ERR (stderr) and ST_EXIT; never aborts.
run_st() {
  set +e
  ST_OUT="$("$PY" -I "$SCRIPT_UNDER_TEST" "$@" 2>"$TEST_ROOT/err")"
  ST_EXIT=$?
  set -e
  ST_ERR="$(cat "$TEST_ROOT/err")"
}

# jget <json-line> <python expression over d> — prints the expression's JSON value.
# The expression is always a literal written in this file, never input data.
jget() {
  printf '%s' "$1" | "$PY" -I -c 'import json, sys; d = json.loads(sys.stdin.read()); print(json.dumps(eval(sys.argv[1])))' "$2"
}

echo "Test 1: two overlapping agents plus a gap over 10 minutes (spec criterion 5)"
# a1: 10:00 10:05 10:15 | 25-minute gap | 10:40 10:50 -> [10:00,10:15] [10:40,10:50] = 25 min.
#     10:05 -> 10:15 is exactly 10 minutes and must join.
# a2: 10:10 10:20 10:30 (written out of order) -> [10:10,10:30] = 20 min.
# Active 45 min = 0.75 h; wall = [10:00,10:30] + [10:40,10:50] = 40 min; avg 1.125; peak 2.
run_st "$FIX/sess-overlap.jsonl"
assert_eq "$ST_EXIT" "0" "exits 0"
assert_contains "$ST_OUT" "Overlap fixture: agents=2 active_hours=0.75 wall_hours=0.67 avg_concurrency=1.12 peak=2" \
  "summary line uses custom-title.json and gives the expected numbers"
assert_contains "$ST_OUT" "2026-10-31T10:00:00.000Z    25.0 min  fablepowers:implementer  Task 1" "agent a1 line"
assert_contains "$ST_OUT" "2026-10-31T10:10:00.000Z    20.0 min  fablepowers:reviewer  Review T1" "agent a2 line"

run_st --json "$FIX/sess-overlap.jsonl"
J="$ST_OUT"
assert_eq "$ST_EXIT" "0" "--json exits 0"
assert_eq "$(jget "$J" 'd["avg_concurrency"]')" "1.125" "--json avg_concurrency is 1.125"
assert_eq "$(jget "$J" 'd["peak"]')" "2" "--json peak is 2"
assert_eq "$(jget "$J" 'd["active_hours"]')" "0.75" "--json active_hours is 0.75"
assert_eq "$(jget "$J" 'd["wall_hours"]')" "0.6667" "--json wall_hours is 0.6667"
assert_eq "$(jget "$J" 'd["intervals"][0]["segments"]')" \
  '[["2026-10-31T10:00:00.000Z", "2026-10-31T10:15:00.000Z"], ["2026-10-31T10:40:00.000Z", "2026-10-31T10:50:00.000Z"]]' \
  "a1 splits at the 25-minute gap and joins across the exact 10-minute gap"

echo "Test 2: --json field names are stable"
assert_eq "$(jget "$J" 'sorted(k for k in d if k in {"agents","active_hours","wall_hours","avg_concurrency","peak","intervals"})')" \
  '["active_hours", "agents", "avg_concurrency", "intervals", "peak", "wall_hours"]' "summary fields present"
assert_eq "$(jget "$J" 'sorted(d["intervals"][0])')" \
  '["agent_id", "description", "segments", "tool_use_id", "type"]' "interval fields exactly as specified"
assert_eq "$(jget "$J" '[(i["agent_id"], i["tool_use_id"], i["type"], i["description"]) for i in d["intervals"]]')" \
  '[["a1", "toolu_a1", "fablepowers:implementer", "Task 1"], ["a2", null, "fablepowers:reviewer", "Review T1"]]' \
  "agent_id from the file name, tool_use_id from meta toolUseId (null when absent)"
assert_eq "$(printf '%s\n' "$J" | wc -l | tr -d ' ')" "1" "one JSON line per session"
run_st --json "$FIX/sess-overlap.jsonl" "$FIX/sess-nosub.jsonl"
assert_eq "$(printf '%s\n' "$ST_OUT" | wc -l | tr -d ' ')" "2" "two transcripts give two JSON lines"

echo "Test 3: zero subagents (no subagents/ directory)"
run_st "$FIX/sess-nosub.jsonl"
assert_eq "$ST_EXIT" "0" "exits 0"
assert_eq "$ST_OUT" "sess-nosub: agents=0 active_hours=0.00 wall_hours=0.00 avg_concurrency=0.00 peak=0" \
  "summary with zeros, titled by session id, no agent lines"
run_st --json "$FIX/sess-nosub.jsonl"
assert_eq "$(jget "$ST_OUT" '[d["agents"], d["active_hours"], d["wall_hours"], d["avg_concurrency"], d["peak"], d["intervals"]]')" \
  '[0, 0.0, 0.0, 0.0, 0, []]' "--json zeros"

echo "Test 4: an agent file with no timestamped lines is skipped"
run_st "$FIX/sess-notime.jsonl"
assert_eq "$ST_EXIT" "0" "exits 0"
assert_contains "$ST_OUT" "sess-notime: agents=1 active_hours=0.10 wall_hours=0.10 avg_concurrency=1.00 peak=1" \
  "only the timestamped agent counts"
if printf '%s' "$ST_OUT" | grep -Fq "No timestamps"; then
  fail "agent without timestamps is not listed"
else
  pass "agent without timestamps is not listed"
fi
assert_eq "$ST_ERR" "" "nothing on stderr"

echo "Test 5: a missing file exits 2"
run_st "$FIX/sess-overlap.jsonl" "$TEST_ROOT/missing.jsonl"
assert_eq "$ST_EXIT" "2" "exits 2"
assert_eq "$ST_OUT" "" "prints nothing on stdout"
assert_contains "$ST_ERR" "missing.jsonl" "names the missing file"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed"
else
  echo "$FAILURES test(s) failed"
fi
exit "$FAILURES"
