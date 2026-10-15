#!/usr/bin/env bash
# Tests for hooks/session-start and the command hooks.json runs it with.
#
# Every hook run goes through the literal "command" string read from a
# hooks.json, with CLAUDE_PLUGIN_ROOT set, through "<shell> -c" the way Claude
# Code runs it. The 0.2.x hook, vendored under fixtures/0.2.x/, is the
# byte-for-byte reference for everything except the preamble line (0.4.0 names
# the harness): new output == 0.2.x output with its preamble swapped for the
# new one. Old and new hooks always run against the same SKILL.md, in temp
# plugin trees. The new preamble and the map are asserted structurally, and
# the injected context is capped at 6,000 characters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE_DIR="$SCRIPT_DIR/fixtures/0.2.x"   # fablepowers 0.2.1: awk/dirname hook, exec'd via its shebang
# HOOKS_JSON / SESSION_START override the files under test (mutation checks on a copy).
HOOKS_JSON="${HOOKS_JSON:-$REPO_ROOT/hooks/hooks.json}"
SESSION_START="${SESSION_START:-$REPO_ROOT/hooks/session-start}"
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
    cp "$BASELINE_DIR/session-start" "$BASELINE_DIR/hooks.json" "$dir/hooks/"
  else
    cp "$SESSION_START" "$dir/hooks/session-start"
    cp "$HOOKS_JSON" "$dir/hooks/hooks.json"
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

# run_with <normal|broken> <tree> <launcher words...>: run the tree's hooks.json
# command as "<launcher> -c <command>"; stdout to $OUT, exit status to $RC.
# normal = the test's environment minus BASH; broken = empty environment with
# PATH=/nonexistent. Extra VAR=value pairs for the hook go in $HOOK_ENV.
run_with() {
  local mode="$1" tree="$2" cmd; shift 2
  cmd="$(hook_cmd "$tree")"
  RC=0
  if [[ "$mode" == normal ]]; then
    OUT="$(cd "$TEST_ROOT" && env -u BASH CLAUDE_PLUGIN_ROOT="$tree" ${HOOK_ENV:-} "$@" -c "$cmd" 2>"$TEST_ROOT/stderr")" || RC=$?
  else
    OUT="$(cd "$TEST_ROOT" && env -i PATH=/nonexistent CLAUDE_PLUGIN_ROOT="$tree" ${HOOK_ENV:-} "$@" -c "$cmd" 2>"$TEST_ROOT/stderr")" || RC=$?
  fi
}
run_normal() { run_with normal "$1" "$SH"; }
run_broken() { run_with broken "$1" "$SH"; }

# context_of <json>: the additionalContext string, or exit 1 if not valid hook JSON.
context_of() {
  printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}

# preamble_of <json>: the context's first line (the preamble).
preamble_of() {
  printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"].split("\n", 1)[0])'
}

# swapped <0.2.x output>: that output with the 0.2.x preamble replaced by the
# new one ($OLD_PRE -> $NEW_PRE, JSON-escaped, exactly one occurrence). This is
# what the new hook must print. Fails (rc 1) if the old preamble is not there.
swapped() {
  python3 -c '
import json, sys
old, new, s = sys.argv[1:4]
esc = lambda x: json.dumps(x, ensure_ascii=False)[1:-1]
if s.count(esc(old)) != 1:
    sys.exit(1)
sys.stdout.write(s.replace(esc(old), esc(new), 1))' "$OLD_PRE" "$NEW_PRE" "$1"
}

# --- (b) normal PATH: byte-identical to the 0.2.x hook, preamble swapped -----

echo "Normal PATH: output byte-identical to the 0.2.x hook's, preamble swapped"

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

# The two preambles, read from each hook's output on the real SKILL.md.
make_tree "$TEST_ROOT/old-real" old "$FIX/real.md"
make_tree "$TEST_ROOT/new-real" new "$FIX/real.md"
run_normal "$TEST_ROOT/old-real"; OLD_PRE="$(preamble_of "$OUT")"
run_normal "$TEST_ROOT/new-real"; NEW_PRE="$(preamble_of "$OUT")"

for fx in "$FIX"/*.md; do
  name="$(basename "$fx" .md)"
  make_tree "$TEST_ROOT/old-$name" old "$fx"
  make_tree "$TEST_ROOT/new-$name" new "$fx"
  run_normal "$TEST_ROOT/old-$name"; old_out="$OUT"; old_rc="$RC"
  run_normal "$TEST_ROOT/new-$name"; new_out="$OUT"; new_rc="$RC"
  want="$(swapped "$old_out" || echo "<0.2.x preamble not found>")"
  if [[ "$old_rc" == 0 && "$new_rc" == 0 && "$want" == "$new_out" ]]; then
    pass "$name: identical after the preamble swap (rc 0)"
  else
    fail "$name: old rc=$old_rc new rc=$new_rc; outputs $([[ "$want" == "$new_out" ]] && echo equal || echo differ)"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$new_out") | head -5 || true
  fi
done

# Command substitution drops trailing newlines; compare raw bytes once too.
run_cmd_bytes() { (cd "$TEST_ROOT" && CLAUDE_PLUGIN_ROOT="$1" "$SH" -c "$(hook_cmd "$1")") > "$2"; }
run_cmd_bytes "$TEST_ROOT/old-real" "$TEST_ROOT/old.bytes"
run_cmd_bytes "$TEST_ROOT/new-real" "$TEST_ROOT/new.bytes"
python3 -c '
import json, sys
old, new, src, dst = sys.argv[1:5]
esc = lambda x: json.dumps(x, ensure_ascii=False)[1:-1].encode()
b = open(src, "rb").read()
open(dst, "wb").write(b.replace(esc(old), esc(new), 1) if b.count(esc(old)) == 1 else b"")
' "$OLD_PRE" "$NEW_PRE" "$TEST_ROOT/old.bytes" "$TEST_ROOT/want.bytes"
if [[ -s "$TEST_ROOT/want.bytes" ]] && cmp -s "$TEST_ROOT/want.bytes" "$TEST_ROOT/new.bytes"; then
  pass "real SKILL.md: raw stdout bytes identical after the preamble swap"
else
  fail "real SKILL.md: raw stdout bytes differ"
fi

# The repo's own hook, run in place, also matches.
run_normal "$REPO_ROOT"; in_place="$OUT"; in_place_rc="$RC"
run_normal "$TEST_ROOT/old-real"
if [[ "$in_place_rc" == 0 && "$in_place" == "$(swapped "$OUT")" ]]; then
  pass "repo hook run in place matches the 0.2.x hook (preamble swapped)"
else
  fail "repo hook run in place differs from the 0.2.x hook"
fi

# --- (f) the new preamble, the map and the size cap ----------------------------

echo "Preamble and map content"

run_normal "$TEST_ROOT/new-real"; new_real="$OUT"   # the hook under test, real SKILL.md

# The preamble names the harness and keeps the Claude Code dispatch mapping in
# the injected context (it must not move out to a reference file).
for needle in 'Claude Code' '`fablepowers:workflow`' 'Skill tool' '`fablepowers:<skill>`' \
  'Agent tool' 'subagent_type: "fablepowers:<agent>"' 'general-purpose' \
  'AskUserQuestion' 'TodoWrite' 'references/claude-code.md'; do
  if [[ "$NEW_PRE" == *"$needle"* ]]; then
    pass "preamble names '$needle'"
  else
    fail "preamble lacks '$needle'"
  fi
done
[[ "$NEW_PRE" != "$OLD_PRE" ]] && pass "preamble differs from 0.2.x's" \
  || fail "preamble is still 0.2.x's"
[[ -f "$REPO_ROOT/skills/workflow/references/claude-code.md" ]] \
  && pass "the reference the preamble names exists" \
  || fail "skills/workflow/references/claude-code.md is missing"

# Context = preamble + blank line + the repo's SKILL.md minus frontmatter, byte
# for byte (trailing newlines dropped, as command substitution drops them).
if python3 -c '
import json, sys
ctx = json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"]
pre, sep, body = ctx.partition("\n\n")
lines = open(sys.argv[2], encoding="utf-8").read().split("\n")
assert lines[0] == "---"
end = lines.index("---", 1)
want = "\n".join(lines[end + 1:]).rstrip("\n")
sys.exit(0 if sep and "\n" not in pre and pre == sys.argv[3] and body == want else 1)
' "$new_real" "$REPO_ROOT/skills/workflow/SKILL.md" "$NEW_PRE"; then
  pass "context is the one-line preamble, a blank line, then the map byte for byte"
else
  fail "context is not preamble + blank line + SKILL.md minus frontmatter"
fi

size="$(context_of "$new_real" | python3 -c 'import sys; print(len(sys.stdin.read()))')"
if [[ "$size" -le 6000 ]]; then
  pass "additionalContext is $size characters (cap 6000)"
else
  fail "additionalContext is $size characters, over the 6000 cap"
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

# --- (e) launchers: sh and bash, BASH unset, normal and broken PATH -----------

echo "Launchers: the literal command via <shell> -c, normal and broken PATH"

run_normal "$TEST_ROOT/old-real"; reference="$(swapped "$OUT")"

# Claude Code runs the command through /bin/sh -c (observed: BASH=/bin/sh with
# "shell": "bash" on Linux), so every launcher runs with BASH removed from the
# environment. A bash launcher sets BASH itself; a non-bash sh (dash) does not,
# which is the case where "${BASH:-bash}" fell back to a PATH lookup.
LAUNCHERS=()
[[ -x /bin/sh ]] && LAUNCHERS+=("/bin/sh")
[[ -x /bin/bash ]] && LAUNCHERS+=("/bin/bash")
NON_BASH=()   # launchers that are not bash, so BASH stays unset
for c in dash busybox; do
  p="$(command -v "$c" 2>/dev/null || true)"
  if [[ -n "$p" ]]; then
    [[ "$c" == busybox ]] && NON_BASH+=("$p sh") || NON_BASH+=("$p")
  fi
done
if p="$(command -v zsh 2>/dev/null)"; then
  # Simulated dash: zsh in sh emulation, no rc files. It never sets BASH.
  NON_BASH+=("$p --emulate sh -f")
fi
if [[ ${#NON_BASH[@]} -eq 0 ]]; then
  echo "  [SKIP] no dash, busybox or zsh: the BASH-unset case is not exercised"
fi
LAUNCHERS+=("${NON_BASH[@]}")

for launcher in "${LAUNCHERS[@]}"; do
  read -ra words <<< "$launcher"
  for mode in normal broken; do
    run_with "$mode" "$TEST_ROOT/new-real" "${words[@]}"
    if [[ "$RC" == 0 && "$OUT" == "$reference" ]]; then
      pass "$launcher -c, $mode PATH: rc 0, output equals the 0.2.x hook's (preamble swapped)"
    else
      fail "$launcher -c, $mode PATH: rc $RC; $(head -c 160 "$TEST_ROOT/stderr" | tr '\n' ' ')"
    fi
  done
done

# The non-bash launchers really reproduce the failure conditions: BASH unset
# and no bash on PATH. Without this, a pass above could be vacuous.
for launcher in "${NON_BASH[@]}"; do
  read -ra words <<< "$launcher"
  probe="$(env -i PATH=/nonexistent "${words[@]}" -c 'echo "BASH=${BASH-unset}"; command -v bash >/dev/null 2>&1 && echo found || echo missing' 2>/dev/null || true)"
  if [[ "$probe" == $'BASH=unset\nmissing' ]]; then
    pass "$launcher, broken PATH: BASH unset and bash not on PATH (the dash failure conditions)"
  else
    fail "$launcher, broken PATH: probe gave '$probe', not the dash failure conditions"
  fi
done

# A BASH inherited from the environment is preferred over the fixed locations
# (only observable from a launcher that does not overwrite BASH itself).
if [[ ${#NON_BASH[@]} -gt 0 ]]; then
  read -ra words <<< "${NON_BASH[0]}"
  marker="$TEST_ROOT/fakebash.ran"
  printf '#!%s\nprintf ran > %q\nexec %q "$@"\n' "$SH" "$marker" "$SH" > "$TEST_ROOT/fakebash"
  chmod +x "$TEST_ROOT/fakebash"
  for mode in normal broken; do
    rm -f "$marker"
    HOOK_ENV="BASH=$TEST_ROOT/fakebash" run_with "$mode" "$TEST_ROOT/new-real" "${words[@]}"
    if [[ "$RC" == 0 && "$OUT" == "$reference" && -e "$marker" ]]; then
      pass "${NON_BASH[0]}, $mode PATH: an inherited BASH is the bash that runs the hook"
    else
      fail "${NON_BASH[0]}, $mode PATH: inherited BASH not used (rc $RC, marker $([[ -e "$marker" ]] && echo present || echo absent))"
    fi
  done
  # An inherited BASH naming a directory ([ -x ] is true for one) is skipped
  # and the launcher falls through to an absolute bash.
  mkdir -p "$TEST_ROOT/bash-is-a-dir"
  for mode in normal broken; do
    HOOK_ENV="BASH=$TEST_ROOT/bash-is-a-dir" run_with "$mode" "$TEST_ROOT/new-real" "${words[@]}"
    if [[ "$RC" == 0 && "$OUT" == "$reference" ]]; then
      pass "${NON_BASH[0]}, $mode PATH: an inherited BASH naming a directory falls through to an absolute bash"
    else
      fail "${NON_BASH[0]}, $mode PATH: inherited BASH naming a directory: rc $RC; $(head -c 160 "$TEST_ROOT/stderr" | tr '\n' ' ')"
    fi
  done
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
[[ "$(swapped "$OUT")" == "$new_missing" ]] && pass "missing file: identical to the 0.2.x hook (preamble swapped)" \
  || fail "missing file: differs from the 0.2.x hook"

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All session-start hook tests passed."
else
  echo "$FAILURES session-start hook test(s) failed."
  exit 1
fi
