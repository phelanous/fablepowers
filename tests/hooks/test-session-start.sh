#!/usr/bin/env bash
# Tests for hooks/session-start and the command hooks.json runs it with.
#
# Every hook run goes through the literal "command" string read from a
# hooks.json, with CLAUDE_PLUGIN_ROOT set, exactly as Claude Code runs it under
# "shell": "bash". The 0.2.x hook (BASELINE_REV) is the byte-for-byte reference;
# old and new hooks always run against the same SKILL.md, in temp plugin trees.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE_REV="839bb3a"   # fablepowers 0.2.1: awk/dirname hook, exec'd via its shebang
SH="$BASH"               # absolute path of the bash running this test

FAILURES=0
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

# --- plugin trees ---------------------------------------------------------

# make_tree <dir> <old|new> <skill-file-or-empty>: a minimal plugin tree with
# the hook of that generation and the given SKILL.md (none if empty).
make_tree() {
  local dir="$1" gen="$2" skill="$3"
  mkdir -p "$dir/hooks"
  if [[ "$gen" == old ]]; then
    git -C "$REPO_ROOT" show "$BASELINE_REV:hooks/session-start" > "$dir/hooks/session-start"
    git -C "$REPO_ROOT" show "$BASELINE_REV:hooks/hooks.json" > "$dir/hooks/hooks.json"
  else
    cp "$REPO_ROOT/hooks/session-start" "$REPO_ROOT/hooks/hooks.json" "$dir/hooks/"
  fi
  chmod +x "$dir/hooks/session-start"
  if [[ -n "$skill" ]]; then
    mkdir -p "$dir/skills/workflow"
    cp "$skill" "$dir/skills/workflow/SKILL.md"
  fi
}

# hook_cmd <tree>: the literal SessionStart command string from its hooks.json.
hook_cmd() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$1/hooks/hooks.json"
}

# run_normal <tree> / run_broken <tree>: run the hooks.json command; stdout to
# $OUT, exit status to $RC. "broken" = empty environment, PATH=/nonexistent.
run_normal() {
  RC=0
  OUT="$(cd "$TEST_ROOT" && CLAUDE_PLUGIN_ROOT="$1" "$SH" -c "$(hook_cmd "$1")" 2>"$TEST_ROOT/stderr")" || RC=$?
}
run_broken() {
  RC=0
  OUT="$(cd "$TEST_ROOT" && env -i PATH=/nonexistent CLAUDE_PLUGIN_ROOT="$1" "$SH" -c "$(hook_cmd "$1")" 2>"$TEST_ROOT/stderr")" || RC=$?
}

# context_of <json>: the additionalContext string, or exit 1 if not valid hook JSON.
context_of() {
  printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}

# --- (b) normal PATH: byte-identical to the 0.2.x hook ----------------------

echo "Normal PATH: output byte-identical to the 0.2.x hook"

FIX="$TEST_ROOT/fixtures"
mkdir -p "$FIX"
cp "$REPO_ROOT/skills/workflow/SKILL.md" "$FIX/real.md"
printf -- '---\nname: x\n---\n\n# Body\n\ntext\n' > "$FIX/basic.md"
printf '# No frontmatter\n\n---\nnot: frontmatter\n---\n' > "$FIX/no-frontmatter.md"
printf -- '---\nname: x\n---\n# A\n---\nkept: yes\n---\nend' > "$FIX/later-rules.md"
printf -- '---\nname: x\ndescription: never closed\n\n# Body\n' > "$FIX/unclosed.md"
printf -- '---\n---\n' > "$FIX/empty-frontmatter.md"
printf -- '---\nname: x\n---' > "$FIX/frontmatter-only.md"
printf '' > "$FIX/empty.md"
printf -- '---\r\nname: x\r\n---\r\n# CRLF\r\n' > "$FIX/crlf.md"
printf -- '----\nname: x\n---\nbody\n' > "$FIX/four-dashes.md"
printf -- ' ---\nname: x\n---\nbody\n' > "$FIX/indented.md"
printf -- '---\nname: x\n --- \n---\n\n\n# Lead blanks "q" \\ back\ttab\n\n\n' > "$FIX/escapes.md"
printf -- '---\nname: x\n---\n---\nbody after second rule' > "$FIX/rule-right-after.md"
printf -- '---' > "$FIX/dashes-only.md"

for fx in "$FIX"/*.md; do
  name="$(basename "$fx" .md)"
  make_tree "$TEST_ROOT/old-$name" old "$fx"
  make_tree "$TEST_ROOT/new-$name" new "$fx"
  run_normal "$TEST_ROOT/old-$name"; old_out="$OUT"; old_rc="$RC"
  run_normal "$TEST_ROOT/new-$name"; new_out="$OUT"; new_rc="$RC"
  if [[ "$old_rc" == 0 && "$new_rc" == 0 && "$old_out" == "$new_out" ]]; then
    pass "$name: identical (rc 0)"
  else
    fail "$name: old rc=$old_rc new rc=$new_rc; outputs $([[ "$old_out" == "$new_out" ]] && echo equal || echo differ)"
    diff <(printf '%s\n' "$old_out") <(printf '%s\n' "$new_out") | head -5 || true
  fi
done

# Command substitution drops trailing newlines; compare raw bytes once too.
run_cmd_bytes() { (cd "$TEST_ROOT" && CLAUDE_PLUGIN_ROOT="$1" "$SH" -c "$(hook_cmd "$1")") > "$2"; }
run_cmd_bytes "$TEST_ROOT/old-real" "$TEST_ROOT/old.bytes"
run_cmd_bytes "$TEST_ROOT/new-real" "$TEST_ROOT/new.bytes"
if cmp -s "$TEST_ROOT/old.bytes" "$TEST_ROOT/new.bytes"; then
  pass "real SKILL.md: raw stdout bytes identical"
else
  fail "real SKILL.md: raw stdout bytes differ"
fi

# The repo's own hook, run in place, also matches.
run_normal "$REPO_ROOT"; in_place="$OUT"; in_place_rc="$RC"
run_normal "$TEST_ROOT/old-real"
if [[ "$in_place_rc" == 0 && "$in_place" == "$OUT" ]]; then
  pass "repo hook run in place matches the 0.2.x hook"
else
  fail "repo hook run in place differs from the 0.2.x hook"
fi

# --- (a) broken PATH ----------------------------------------------------------

echo "Broken PATH (env -i PATH=/nonexistent)"

first_heading="$(grep -m1 '^# ' "$FIX/real.md")"

run_broken "$TEST_ROOT/new-real"
if ctx="$(context_of "$OUT")"; then
  pass "new hook: valid hook JSON (rc $RC)"
  [[ "$RC" == 0 ]] && pass "new hook: exit 0" || fail "new hook: exit $RC"
  if [[ "$ctx" == *"$first_heading"* ]]; then
    pass "new hook: context contains the map heading '$first_heading'"
  else
    fail "new hook: context lacks '$first_heading'"
  fi
  if printf '%s\n' "$ctx" | grep -qx 'name: workflow'; then
    fail "new hook: context contains the frontmatter line 'name: workflow'"
  else
    pass "new hook: no frontmatter line in context"
  fi
else
  fail "new hook: output is not valid hook JSON (rc $RC): $(head -c 200 "$TEST_ROOT/stderr")"
fi

run_normal "$TEST_ROOT/new-real"; normal_out="$OUT"
run_broken "$TEST_ROOT/new-real"
if [[ "$OUT" == "$normal_out" ]]; then
  pass "new hook: broken-PATH output equals normal-PATH output"
else
  fail "new hook: broken-PATH output differs from normal-PATH output"
fi

run_broken "$TEST_ROOT/old-real"
if [[ "$RC" != 0 ]] || ! context_of "$OUT" >/dev/null 2>&1; then
  pass "0.2.x hook fails the same run (rc $RC: $(head -c 80 "$TEST_ROOT/stderr" | tr '\n' ' '))"
else
  fail "0.2.x hook unexpectedly succeeded under a broken PATH; the test does not reproduce the failure"
fi

# --- (c) relative, no-slash and absolute invocation ---------------------------

echo "Direct invocation of the script"

expected="$normal_out"
T="$TEST_ROOT/new-real"
check_invocation() {
  local label="$1"; shift
  local got rc=0
  got="$("$@" 2>"$TEST_ROOT/stderr")" || rc=$?
  if [[ "$rc" == 0 && "$got" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (rc $rc; $(head -c 120 "$TEST_ROOT/stderr"))"
  fi
}
check_invocation "relative: bash hooks/session-start" \
  bash -c 'cd "$1" && "$2" hooks/session-start' _ "$T" "$SH"
check_invocation "no slash: bash session-start from hooks/" \
  bash -c 'cd "$1/hooks" && "$2" session-start' _ "$T" "$SH"
check_invocation "relative exec: ./session-start from hooks/" \
  bash -c 'cd "$1/hooks" && ./session-start' _ "$T"
check_invocation "absolute: bash <abs>/hooks/session-start" \
  "$SH" "$T/hooks/session-start"
check_invocation "relative, broken PATH: env -i PATH=/nonexistent bash hooks/session-start" \
  bash -c 'cd "$1" && env -i PATH=/nonexistent "$2" hooks/session-start' _ "$T" "$SH"
check_invocation "relative with ..: bash hooks/../hooks/session-start" \
  bash -c 'cd "$1" && "$2" hooks/../hooks/session-start' _ "$T" "$SH"

# --- (d) missing SKILL.md ------------------------------------------------------

echo "Missing workflow SKILL.md"

make_tree "$TEST_ROOT/new-missing" new ""
make_tree "$TEST_ROOT/old-missing" old ""
for mode in normal broken; do
  "run_$mode" "$TEST_ROOT/new-missing"
  if [[ "$RC" == 0 ]] && ctx="$(context_of "$OUT")" && [[ "$ctx" == *"Error reading the fablepowers:workflow skill"* ]]; then
    pass "$mode PATH: fallback message, exit 0"
  else
    fail "$mode PATH: expected fallback message and exit 0 (rc $RC)"
  fi
done
run_normal "$TEST_ROOT/new-missing"; new_missing="$OUT"
run_normal "$TEST_ROOT/old-missing"
[[ "$OUT" == "$new_missing" ]] && pass "missing file: identical to the 0.2.x hook" \
  || fail "missing file: differs from the 0.2.x hook"

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All session-start hook tests passed."
else
  echo "$FAILURES session-start hook test(s) failed."
  exit 1
fi
