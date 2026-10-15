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
#
# 0.5.0 adds harness detection from the SessionStart payload on stdin. Every
# hook run gets empty stdin unless a test passes a payload ($HOOK_STDIN). On a
# Claude Code payload the output must stay byte-identical to the empty-stdin
# (0.4.0) output; on a Codex payload the context is the Codex preamble with the
# seat table (from models.toml) followed by the same map, capped at 8,000.
set -euo pipefail

# No hook run inherits the runner's stdin: empty stdin is the 0.4.0 case.
exec </dev/null

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE_DIR="$SCRIPT_DIR/fixtures/0.2.x"   # fablepowers 0.2.1: awk/dirname hook, exec'd via its shebang
SS_FIX="$SCRIPT_DIR/fixtures/session-start" # real SessionStart payloads (Codex, Claude Code)
CLAUDE_PAYLOAD="$SS_FIX/claude-sessionstart-startup.json"
CODEX_PAYLOAD="$SS_FIX/codex-sessionstart-startup-exec.json"
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
# normal = the test's environment minus BASH and PLUGIN_ROOT, with
# XDG_CONFIG_HOME pointing at an empty directory (no user models.toml); broken =
# empty environment with PATH=/nonexistent. Extra VAR=value pairs for the hook
# go in $HOOK_ENV; the hook's stdin is $HOOK_STDIN (default /dev/null).
run_with() {
  local mode="$1" tree="$2" cmd; shift 2
  cmd="$(hook_cmd "$tree")"
  RC=0
  if [[ "$mode" == normal ]]; then
    OUT="$(cd "$TEST_ROOT" && env -u BASH -u PLUGIN_ROOT -u CODEX_HOME XDG_CONFIG_HOME="$TEST_ROOT/xdg-empty" CLAUDE_PLUGIN_ROOT="$tree" ${HOOK_ENV:-} "$@" -c "$cmd" <"${HOOK_STDIN:-/dev/null}" 2>"$TEST_ROOT/stderr")" || RC=$?
  else
    OUT="$(cd "$TEST_ROOT" && env -i PATH=/nonexistent CLAUDE_PLUGIN_ROOT="$tree" ${HOOK_ENV:-} "$@" -c "$cmd" <"${HOOK_STDIN:-/dev/null}" 2>"$TEST_ROOT/stderr")" || RC=$?
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
  # A real Claude Code SessionStart payload on stdin changes nothing.
  HOOK_STDIN="$CLAUDE_PAYLOAD" run_normal "$TEST_ROOT/new-$name"
  if [[ "$RC" == 0 && "$OUT" == "$want" ]]; then
    pass "$name: Claude Code payload on stdin: same output (rc 0)"
  else
    fail "$name: Claude Code payload on stdin: rc $RC, output differs from the empty-stdin output"
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

# The Codex reference: the real Codex payload with a models.toml setting every
# key, so the parser also runs under every launcher and a broken PATH.
CODEX_XDG="$TEST_ROOT/xdg-full"
mkdir -p "$CODEX_XDG/fablepowers"
cp "$SS_FIX/models-full.toml" "$CODEX_XDG/fablepowers/models.toml"
HOOK_STDIN="$CODEX_PAYLOAD" HOOK_ENV="XDG_CONFIG_HOME=$CODEX_XDG" run_normal "$TEST_ROOT/new-real"
codex_reference="$OUT"

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
    HOOK_STDIN="$CLAUDE_PAYLOAD" run_with "$mode" "$TEST_ROOT/new-real" "${words[@]}"
    if [[ "$RC" == 0 && "$OUT" == "$reference" ]]; then
      pass "$launcher -c, $mode PATH, Claude Code payload: rc 0, same output"
    else
      fail "$launcher -c, $mode PATH, Claude Code payload: rc $RC; $(head -c 160 "$TEST_ROOT/stderr" | tr '\n' ' ')"
    fi
    HOOK_STDIN="$CODEX_PAYLOAD" HOOK_ENV="XDG_CONFIG_HOME=$CODEX_XDG" run_with "$mode" "$TEST_ROOT/new-real" "${words[@]}"
    if [[ "$RC" == 0 && "$OUT" == "$codex_reference" ]]; then
      pass "$launcher -c, $mode PATH, Codex payload + models.toml: rc 0, output equals the Codex reference"
    else
      fail "$launcher -c, $mode PATH, Codex payload + models.toml: rc $RC; $(head -c 160 "$TEST_ROOT/stderr" | tr '\n' ' ')"
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

# --- (g) stdin: harness detection, never blocking -------------------------------

echo "Harness detection from the SessionStart payload"

T="$TEST_ROOT/new-real"
run_normal "$T"; claude_ref="$OUT"   # empty stdin: the 0.4.0 output

# is_codex <json>: the context starts with the Codex preamble.
is_codex() { [[ "$(preamble_of "$1" 2>/dev/null)" == "You have fablepowers on Codex."* ]]; }

for fx in "$SS_FIX"/codex-sessionstart-*.json; do
  HOOK_STDIN="$fx" run_normal "$T"
  if [[ "$RC" == 0 ]] && is_codex "$OUT"; then
    pass "$(basename "$fx"): Codex preamble (rc 0)"
  else
    fail "$(basename "$fx"): no Codex preamble (rc $RC)"
  fi
done

# Raw stdout bytes for each real Claude Code payload (startup, resume, and the
# compact one, which carries "model") equal the empty-stdin bytes.
for fx in "$SS_FIX"/claude-sessionstart-*.json; do
  (cd "$TEST_ROOT" && env -u PLUGIN_ROOT -u CODEX_HOME CLAUDE_PLUGIN_ROOT="$T" "$SH" -c "$(hook_cmd "$T")" <"$fx") > "$TEST_ROOT/claude-payload.bytes"
  if cmp -s "$TEST_ROOT/new.bytes" "$TEST_ROOT/claude-payload.bytes"; then
    pass "$(basename "$fx"): raw stdout bytes identical to the empty-stdin run"
  else
    fail "$(basename "$fx"): raw stdout bytes differ from the empty-stdin run"
  fi
done

# detect <label> <codex|claude> <payload text> [VAR=value ...]: run with that
# payload (and extra env) and check the harness the output shows.
detect() {
  local label="$1" want="$2" body="$3"; shift 3
  printf '%s' "$body" > "$TEST_ROOT/payload.json"
  HOOK_STDIN="$TEST_ROOT/payload.json" HOOK_ENV="$*" run_normal "$T"
  if [[ "$RC" != 0 ]]; then
    fail "$label: rc $RC"
  elif [[ "$want" == codex ]] && is_codex "$OUT"; then
    pass "$label: Codex"
  elif [[ "$want" == claude && "$OUT" == "$claude_ref" ]]; then
    pass "$label: Claude Code, output identical to the empty-stdin run"
  else
    fail "$label: expected $want"
  fi
}
# Neither "model" nor "permission_mode" means Codex: Claude Code's compact
# SessionStart carries "model" (claude-sessionstart-compact.json).
detect "permission_mode key only" claude '{"hook_event_name":"SessionStart","permission_mode":"default"}'
detect "model key only" claude '{"hook_event_name":"SessionStart","model":"gpt-6-luna"}'
detect "Claude Code compact payload with model and a <uuid>.jsonl transcript" claude '{"transcript_path":"/h/.claude/projects/p/80425774-bd1b-4e39-bc07-2acaa47d81fe.jsonl","hook_event_name":"SessionStart","source":"compact","model":"claude-opus-5-5","permission_mode":"default"}'
detect "transcript_path basename rollout-*.jsonl only" codex '{"transcript_path":"/h/.codex/sessions/2026/10/15/rollout-2026-a.jsonl"}'
detect "transcript_path rollout-*.jsonl outside any .codex dir" codex '{"transcript_path":"/x/y/rollout-2026-a.jsonl"}'
detect "transcript_path with escaped slashes" codex '{"transcript_path":"\/h\/.codex\/sessions\/rollout-x.jsonl"}'
detect "transcript_path under .codex/sessions/ (other basename)" codex '{"transcript_path":"/h/.codex/sessions/2026/10/15/abc.jsonl"}'
detect "transcript_path under .codex/sessions/, escaped slashes" codex '{"transcript_path":"\/h\/.codex\/sessions\/abc.jsonl"}'
detect "transcript_path under \$CODEX_HOME/sessions/" codex '{"transcript_path":"/srv/cx/sessions/2026/abc.jsonl"}' "CODEX_HOME=/srv/cx/"
detect "transcript_path under a CODEX_HOME-like dir, CODEX_HOME unset" claude '{"transcript_path":"/srv/cx/sessions/2026/abc.jsonl"}'
detect "transcript_path under .codex/ but not sessions/" claude '{"transcript_path":"/h/.codex/other/abc.jsonl"}'
detect "transcript_path rollout-*.json (not .jsonl)" claude '{"transcript_path":"/h/.codex/other/rollout-x.json"}'
detect "transcript_path basename myrollout-*.jsonl" claude '{"transcript_path":"/h/myrollout-x.jsonl"}'
detect "rollout- only in a directory name" claude '{"transcript_path":"/h/rollout-dir/abc.jsonl"}'
detect "transcript_path key spelled differently" claude '{"transcript":"/h/rollout-x.jsonl"}'
detect "\"transcript_path\" escaped inside a string value" claude '{"cwd":"/a/\"transcript_path\": \"/h/rollout-x.jsonl\""}'
detect "PLUGIN_ROOT equal to CLAUDE_PLUGIN_ROOT, empty payload" codex '' "PLUGIN_ROOT=$T"
detect "PLUGIN_ROOT equal to CLAUDE_PLUGIN_ROOT, Claude Code payload" codex "$(<"$CLAUDE_PAYLOAD")" "PLUGIN_ROOT=$T"
detect "PLUGIN_ROOT set to another directory" claude "$(<"$CLAUDE_PAYLOAD")" "PLUGIN_ROOT=$TEST_ROOT/elsewhere"
detect "PLUGIN_ROOT empty" claude '' "PLUGIN_ROOT="
detect "not JSON" claude 'hello'

# A stdin that never closes does not block: the read times out (1 s).
mkfifo "$TEST_ROOT/fifo"
exec 9<>"$TEST_ROOT/fifo"
t0=$SECONDS
RC=0
OUT="$(cd "$TEST_ROOT" && timeout 15 env -u BASH -u PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$T" "$SH" -c "$(hook_cmd "$T")" <"$TEST_ROOT/fifo" 2>"$TEST_ROOT/stderr")" || RC=$?
elapsed=$((SECONDS - t0))
if [[ "$RC" == 0 && "$elapsed" -le 3 && "$OUT" == "$claude_ref" ]]; then
  pass "stdin never closes, no data: rc 0 in ${elapsed}s (<= 3), Claude Code output"
else
  fail "stdin never closes, no data: rc $RC after ${elapsed}s"
fi
# Same, with a payload written but stdin still open.
printf '%s' "$(<"$CODEX_PAYLOAD")" >&9
t0=$SECONDS
RC=0
OUT="$(cd "$TEST_ROOT" && timeout 15 env -u BASH -u PLUGIN_ROOT XDG_CONFIG_HOME="$TEST_ROOT/xdg-empty" CLAUDE_PLUGIN_ROOT="$T" "$SH" -c "$(hook_cmd "$T")" <"$TEST_ROOT/fifo" 2>"$TEST_ROOT/stderr")" || RC=$?
elapsed=$((SECONDS - t0))
if [[ "$RC" == 0 && "$elapsed" -le 3 ]] && context_of "$OUT" >/dev/null; then
  pass "stdin never closes after a payload: rc 0 in ${elapsed}s (<= 3), valid hook JSON ($(is_codex "$OUT" && echo Codex || echo 'Claude Code'))"
else
  fail "stdin never closes after a payload: rc $RC after ${elapsed}s"
fi
exec 9>&-

# Closed stdin (not just empty) also gives the 0.4.0 output.
RC=0
OUT="$(cd "$TEST_ROOT" && env -u BASH -u PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$T" "$SH" -c "$(hook_cmd "$T")" <&- 2>"$TEST_ROOT/stderr")" || RC=$?
if [[ "$RC" == 0 && "$OUT" == "$claude_ref" ]]; then
  pass "closed stdin: rc 0, Claude Code output"
else
  fail "closed stdin: rc $RC, output differs"
fi

# --- (h) the Codex preamble, the map and the size cap --------------------------

echo "Codex preamble and map"

# codex_parts <json>: checks context = preamble + blank line + SKILL.md minus
# frontmatter (byte for byte), the preamble has no blank line; prints the preamble.
codex_parts() {
  python3 -c '
import json, sys
ctx = json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"]
lines = open(sys.argv[2], encoding="utf-8").read().split("\n")
end = lines.index("---", 1)
body = "\n".join(lines[end + 1:]).rstrip("\n")
pre = ctx[: len(ctx) - len(body) - 2]
if not ctx.endswith("\n\n" + body) or "\n\n" in pre:
    sys.exit(1)
sys.stdout.write(pre)' "$1" "$REPO_ROOT/skills/workflow/SKILL.md"
}

# seats_of <json>: "implementer=M/E strict_implementer=M/E reviewer=M/E" from the seat table.
seats_of() {
  printf '%s' "$1" | python3 -c '
import json, re, sys
ctx = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
pre = ctx.split("\n\n", 1)[0]
out = []
for seat, f in (("implementer", "implementer"), ("strict_implementer", "strict-implementer"), ("reviewer", "reviewer")):
    m = re.search(r"^- %s \(agents/%s\.md\): model (\S+), reasoning_effort (\S+)$" % (seat, f), pre, re.M)
    out.append("%s=%s/%s" % (seat, m.group(1), m.group(2)) if m else seat + "=MISSING")
print(" ".join(out))'
}

# warnings_of <json>: the warning lines (one per line), empty if none.
warnings_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
ctx = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
pre = ctx.split("\n\n", 1)[0].split("\n")
i = next((k for k, l in enumerate(pre) if l.startswith("models.toml warnings (")), None)
if i is not None:
    sys.stdout.write("\n".join(pre[i:]))'
}

DEFAULT_SEATS="implementer=gpt-6.1-sol/high strict_implementer=gpt-5.6-terra/medium reviewer=gpt-6.1-sol/high"

HOOK_STDIN="$CODEX_PAYLOAD" run_normal "$T"; codex_default="$OUT"
if pre="$(codex_parts "$codex_default")"; then
  pass "Codex context is the preamble, a blank line, then the map byte for byte"
else
  fail "Codex context is not preamble + blank line + SKILL.md minus frontmatter"
  pre=""
fi
for needle in 'You have fablepowers on Codex.' '`fablepowers:workflow`' \
  "\`$T/skills/workflow/references/codex.md\`" "Plugin root: \`$T\`." \
  "Seat table (defaults, overridden by the [codex] table of $TEST_ROOT/xdg-empty/fablepowers/models.toml)" \
  'reasoning_effort'; do
  [[ "$pre" == *"$needle"* ]] && pass "Codex preamble names '$needle'" || fail "Codex preamble lacks '$needle'"
done
for needle in 'Claude Code' 'AskUserQuestion' 'TodoWrite' 'Agent tool' 'Skill tool' 'models.toml warnings'; do
  [[ "$pre" != *"$needle"* ]] && pass "Codex preamble does not mention '$needle'" || fail "Codex preamble mentions '$needle'"
done
got="$(seats_of "$codex_default")"
[[ "$got" == "$DEFAULT_SEATS" ]] && pass "no models.toml: default seat table" || fail "no models.toml: seats '$got'"
size="$(context_of "$codex_default" | python3 -c 'import sys; print(len(sys.stdin.read()))')"
[[ "$size" -le 8000 ]] && pass "Codex additionalContext is $size characters (cap 8000)" \
  || fail "Codex additionalContext is $size characters, over the 8000 cap"

# The plugin root is absolute even when the hook is invoked by a relative path.
for inv in 'hooks/session-start' './hooks/../hooks/session-start'; do
  RC=0
  OUT="$(cd "$T" && env -u PLUGIN_ROOT XDG_CONFIG_HOME="$TEST_ROOT/xdg-empty" "$SH" $inv <"$CODEX_PAYLOAD" 2>"$TEST_ROOT/stderr")" || RC=$?
  if [[ "$RC" == 0 && "$OUT" == "$codex_default" ]]; then
    pass "relative invocation '$inv': same Codex output (absolute plugin root)"
  else
    fail "relative invocation '$inv': rc $RC, output differs"
  fi
done
RC=0
OUT="$(cd "$T/hooks" && env -u PLUGIN_ROOT XDG_CONFIG_HOME="$TEST_ROOT/xdg-empty" "$SH" session-start <"$CODEX_PAYLOAD" 2>"$TEST_ROOT/stderr")" || RC=$?
[[ "$RC" == 0 && "$OUT" == "$codex_default" ]] && pass "no-slash invocation from hooks/: same Codex output" \
  || fail "no-slash invocation from hooks/: rc $RC, output differs"

# Neither HOME nor XDG_CONFIG_HOME (broken PATH, empty env): defaults, said so.
HOOK_STDIN="$CODEX_PAYLOAD" run_broken "$T"
if [[ "$RC" == 0 && "$(seats_of "$OUT")" == "$DEFAULT_SEATS" && "$(preamble_of "$OUT" 2>/dev/null; context_of "$OUT")" == *"no models.toml since HOME and XDG_CONFIG_HOME are unset"* ]]; then
  pass "no HOME, no XDG_CONFIG_HOME: defaults, and the preamble says why"
else
  fail "no HOME, no XDG_CONFIG_HOME: rc $RC, seats '$(seats_of "$OUT" 2>/dev/null)'"
fi

# --- (i) models.toml -------------------------------------------------------------

echo "models.toml parser"

XN=0
# toml_run <file-or-empty> [VAR=value ...]: Codex run with that file as
# $XDG_CONFIG_HOME/fablepowers/models.toml (none if empty).
toml_run() {
  local src="$1"; shift
  XN=$((XN + 1))
  local xdg="$TEST_ROOT/xdg-$XN"
  mkdir -p "$xdg/fablepowers"
  [[ -n "$src" ]] && cp "$src" "$xdg/fablepowers/models.toml"
  HOOK_STDIN="$CODEX_PAYLOAD" HOOK_ENV="XDG_CONFIG_HOME=$xdg $*" run_normal "$T"
}

# toml_case <label> <content (printf format)> <expected seats> <expected warning count> [warning substring]
toml_case() {
  local label="$1" content="$2" want_seats="$3" want_n="$4" want_w="${5:-}" got_w n
  printf -- "$content" > "$TEST_ROOT/models.toml"
  toml_run "$TEST_ROOT/models.toml"
  got_w="$(warnings_of "$OUT")"
  if [[ -z "$got_w" ]]; then n=0; else n="${got_w%%)*}"; n="${n##*(}"; fi
  if [[ "$RC" == 0 && "$(seats_of "$OUT")" == "$want_seats" && "$n" == "$want_n" && "$got_w" == *"$want_w"* ]]; then
    pass "$label"
  else
    fail "$label: rc $RC, seats '$(seats_of "$OUT" 2>/dev/null)', warnings ($n): $(printf '%s' "$got_w" | tr '\n' '|')"
  fi
}

S_IMPL_LUNA="implementer=gpt-6-luna/high strict_implementer=gpt-5.6-terra/medium reviewer=gpt-6.1-sol/high"

toml_run "$SS_FIX/models-full.toml"
want="implementer=gpt-6-luna/low strict_implementer=org/model-1.2:beta/xhigh reviewer=gpt-5.6-luna/max"
if [[ "$(seats_of "$OUT")" == "$want" && -z "$(warnings_of "$OUT")" ]]; then
  pass "every [codex] key overrides its default; [claude-code] and [other] ignored; no warnings"
else
  fail "models-full.toml: seats '$(seats_of "$OUT")', warnings '$(warnings_of "$OUT")'"
fi
[[ "$(context_of "$OUT")" == *"overridden by the [codex] table of $TEST_ROOT/xdg-$XN/fablepowers/models.toml"* ]] \
  && pass "the seat table names the models.toml it read" || fail "the seat table does not name the models.toml path"

toml_run ""
[[ "$(seats_of "$OUT")" == "$DEFAULT_SEATS" && -z "$(warnings_of "$OUT")" ]] \
  && pass "missing file: defaults, no warning" || fail "missing file: seats '$(seats_of "$OUT")', warnings '$(warnings_of "$OUT")'"

toml_case "empty file: defaults, no warning" '' "$DEFAULT_SEATS" 0
toml_case "comments, blank lines and indentation" '# c\n\n[codex]\n  # indented comment\n\timplementer = "gpt-6-luna"   # trailing # comment\n\n' "$S_IMPL_LUNA" 0
toml_case "keys before any table are ignored" 'implementer = "gpt-6-luna"\n[codex]\n' "$DEFAULT_SEATS" 0
toml_case "only [codex] is read; malformed lines elsewhere ignored" '[claude-code]\nimplementer = "x1"\nnot a line\n[codex]\nimplementer = "gpt-6-luna"\n[codex.sub]\nreviewer = "x2"\n[[codex]]\nreviewer = "x3"\n' "$S_IMPL_LUNA" 0
toml_case "table header with spaces and a trailing comment" '[ codex ] # mine\nimplementer = "gpt-6-luna"\n' "$S_IMPL_LUNA" 0
toml_case "CRLF line endings" '[codex]\r\nimplementer = "gpt-6-luna"\r\nimplementer_effort = "high" # c\r\n' "$S_IMPL_LUNA" 0
toml_case "UTF-8 BOM" '\xef\xbb\xbf[codex]\nimplementer = "gpt-6-luna"\n' "$S_IMPL_LUNA" 0
toml_case "BOM only stripped on line 1" '[codex]\n\xef\xbb\xbfimplementer = "gpt-6-luna"\n' "$DEFAULT_SEATS" 1 "line 2: malformed key"
toml_case "no newline at end of file" '[codex]\nimplementer = "gpt-6-luna"' "$S_IMPL_LUNA" 0
toml_case "single-quoted value: default + warning" "[codex]\nimplementer = 'gpt-6-luna'\n" "$DEFAULT_SEATS" 1 "line 2: implementer is single-quoted (use double quotes); using the default gpt-6.1-sol."
toml_case "unquoted value: default + warning" '[codex]\nimplementer = gpt-6-luna\n' "$DEFAULT_SEATS" 1 "line 2: implementer is not a double-quoted string"
toml_case "unterminated string: default + warning" '[codex]\nimplementer = "gpt-6-luna\n' "$DEFAULT_SEATS" 1 "unterminated"
toml_case "text after the value: default + warning" '[codex]\nimplementer = "gpt-6-luna" x\n' "$DEFAULT_SEATS" 1 "text after the value"
toml_case "duplicate key: last wins + warning" '[codex]\nimplementer = "a1"\nimplementer = "gpt-6-luna"\n' "$S_IMPL_LUNA" 1 "line 3: duplicate key implementer"
toml_case "duplicate key, last invalid: default + 2 warnings" '[codex]\nimplementer = "gpt-6-luna"\nimplementer = "bad id"\n' "$DEFAULT_SEATS" 2 "duplicate key implementer"
toml_case "duplicate key across two [codex] tables: last wins" '[codex]\nimplementer = "a1"\n[other]\n[codex]\nimplementer = "gpt-6-luna"\n' "$S_IMPL_LUNA" 1 "duplicate"
toml_case "model id with a space: default + warning" '[codex]\nimplementer = "gpt 6"\n' "$DEFAULT_SEATS" 1 "line 2: implementer is not a valid model id; using the default gpt-6.1-sol."
toml_case "model id with a +: default + warning" '[codex]\nimplementer = "gpt+6"\n' "$DEFAULT_SEATS" 1 "not a valid model id"
toml_case "model id with a non-ASCII letter: default + warning" '[codex]\nimplementer = "gpt-\xc3\xa9"\n' "$DEFAULT_SEATS" 1 "not a valid model id"
toml_case "model id with # inside the quotes: default + warning" '[codex]\nimplementer = "gpt#6"\n' "$DEFAULT_SEATS" 1 "not a valid model id"
toml_case "empty model id: default + warning" '[codex]\nimplementer = ""\n' "$DEFAULT_SEATS" 1 "not a valid model id"
id64="$(printf 'a%.0s' {1..64})"
toml_case "64-character model id accepted" "[codex]\nreviewer = \"$id64\"\n" "implementer=gpt-6.1-sol/high strict_implementer=gpt-5.6-terra/medium reviewer=$id64/high" 0
toml_case "65-character model id: default + warning" "[codex]\nreviewer = \"${id64}b\"\n" "$DEFAULT_SEATS" 1 "reviewer is not a valid model id"
toml_case "model id characters . _ : / - and digits accepted" '[codex]\nstrict_implementer = "A.z_:0/9-x"\n' "implementer=gpt-6.1-sol/high strict_implementer=A.z_:0/9-x/medium reviewer=gpt-6.1-sol/high" 0
for e in low medium high xhigh max ultra; do
  toml_case "effort '$e' accepted" "[codex]\nstrict_implementer_effort = \"$e\"\n" "implementer=gpt-6.1-sol/high strict_implementer=gpt-5.6-terra/$e reviewer=gpt-6.1-sol/high" 0
done
toml_case "effort 'minimal': default + warning" '[codex]\nreviewer_effort = "minimal"\n' "$DEFAULT_SEATS" 1 "line 2: reviewer_effort is not low, medium, high, xhigh, max or ultra; using the default high."
toml_case "effort 'High' (case matters): default + warning" '[codex]\nimplementer_effort = "High"\n' "$DEFAULT_SEATS" 1 "implementer_effort is not low"
toml_case "unknown key: ignored + warning" '[codex]\norchestrator = "gpt-6-luna"\n' "$DEFAULT_SEATS" 1 "line 2: unknown key orchestrator; ignored."
toml_case "quoted key: ignored + warning" '[codex]\n"implementer" = "gpt-6-luna"\n' "$DEFAULT_SEATS" 1 "line 2: malformed key"
toml_case "line without =: ignored + warning" '[codex]\nimplementer\n' "$DEFAULT_SEATS" 1 "line 2: not a key = \"value\" line"
toml_case "malformed table header: warning, table not read" '[codex\nimplementer = "gpt-6-luna"\n' "$DEFAULT_SEATS" 1 "line 1: malformed table header"
toml_case "five warnings: three listed, then the count of the rest" '[codex]\na1 = "x"\na2 = "x"\na3 = "x"\na4 = "x"\na5 = "x"\n' "$DEFAULT_SEATS" 5 "- … 2 more"
printf '[codex]\na1 = "x"\na2 = "x"\na3 = "x"\na4 = "x"\na5 = "x"\n' > "$TEST_ROOT/models.toml"
toml_run "$TEST_ROOT/models.toml"
w="$(warnings_of "$OUT")"
if [[ "$w" == $'models.toml warnings (5):\n- line 2: unknown key a1; ignored.\n- line 3: unknown key a2; ignored.\n- line 4: unknown key a3; ignored.\n- … 2 more' ]]; then
  pass "warning block is exactly: header, 3 warning lines, '… 2 more'"
else
  fail "warning block: $(printf '%s' "$w" | tr '\n' '|')"
fi
toml_case "three warnings: no '… more' line" '[codex]\na1 = "x"\na2 = "x"\na3 = "x"\n' "$DEFAULT_SEATS" 3 "line 4: unknown key a3; ignored."
w="$(warnings_of "$OUT")"
[[ "$w" != *"more"* ]] && pass "three warnings: all listed, no '… more' line" || fail "three warnings: '$w'"

# A long unknown key is cut to 32 characters in its warning.
long_key="$(printf 'k%.0s' {1..200})"
toml_case "a long unknown key is cut to 32 characters" "[codex]\n$long_key = \"x\"\n" "$DEFAULT_SEATS" 1 "unknown key $(printf 'k%.0s' {1..32}); ignored."

# Unreadable file and a directory in its place.
mkdir -p "$TEST_ROOT/xdg-dir/fablepowers/models.toml"
HOOK_STDIN="$CODEX_PAYLOAD" HOOK_ENV="XDG_CONFIG_HOME=$TEST_ROOT/xdg-dir" run_normal "$T"
[[ "$(seats_of "$OUT")" == "$DEFAULT_SEATS" && "$(warnings_of "$OUT")" == *"models.toml is not a readable file; using the defaults."* ]] \
  && pass "models.toml is a directory: defaults + warning" || fail "models.toml is a directory: '$(warnings_of "$OUT")'"
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$TEST_ROOT/xdg-unread/fablepowers"
  printf '[codex]\nimplementer = "gpt-6-luna"\n' > "$TEST_ROOT/xdg-unread/fablepowers/models.toml"
  chmod 000 "$TEST_ROOT/xdg-unread/fablepowers/models.toml"
  HOOK_STDIN="$CODEX_PAYLOAD" HOOK_ENV="XDG_CONFIG_HOME=$TEST_ROOT/xdg-unread" run_normal "$T"
  [[ "$RC" == 0 && "$(seats_of "$OUT")" == "$DEFAULT_SEATS" && "$(warnings_of "$OUT")" == *"not a readable file"* ]] \
    && pass "unreadable models.toml: defaults + warning" || fail "unreadable models.toml: rc $RC '$(warnings_of "$OUT")'"
  chmod 600 "$TEST_ROOT/xdg-unread/fablepowers/models.toml"
else
  echo "  [SKIP] running as root: an unreadable file cannot be made"
fi

# Location: $XDG_CONFIG_HOME wins; empty or unset falls back to $HOME/.config.
mkdir -p "$TEST_ROOT/home/.config/fablepowers" "$TEST_ROOT/xdg-x/fablepowers"
printf '[codex]\nimplementer = "gpt-6-luna"\n' > "$TEST_ROOT/home/.config/fablepowers/models.toml"
printf '[codex]\nreviewer = "gpt-6-luna"\n' > "$TEST_ROOT/xdg-x/fablepowers/models.toml"
HOOK_STDIN="$CODEX_PAYLOAD" HOOK_ENV="HOME=$TEST_ROOT/home XDG_CONFIG_HOME=" run_normal "$T"
[[ "$(seats_of "$OUT")" == "$S_IMPL_LUNA" ]] && pass "XDG_CONFIG_HOME empty: \$HOME/.config/fablepowers/models.toml read" \
  || fail "XDG_CONFIG_HOME empty: seats '$(seats_of "$OUT")'"
HOOK_STDIN="$CODEX_PAYLOAD" HOOK_ENV="HOME=$TEST_ROOT/home" run_broken "$T"
[[ "$(seats_of "$OUT")" == "$S_IMPL_LUNA" ]] && pass "XDG_CONFIG_HOME unset (broken PATH): \$HOME/.config used" \
  || fail "XDG_CONFIG_HOME unset: seats '$(seats_of "$OUT")'"
HOOK_STDIN="$CODEX_PAYLOAD" HOOK_ENV="HOME=$TEST_ROOT/home XDG_CONFIG_HOME=$TEST_ROOT/xdg-x" run_normal "$T"
[[ "$(seats_of "$OUT")" == "implementer=gpt-6.1-sol/high strict_implementer=gpt-5.6-terra/medium reviewer=gpt-6-luna/high" ]] \
  && pass "XDG_CONFIG_HOME set: its models.toml wins over \$HOME/.config" || fail "XDG_CONFIG_HOME set: seats '$(seats_of "$OUT")'"

# models.toml is read only on the Codex path: a broken file changes nothing on Claude Code.
mkdir -p "$TEST_ROOT/xdg-bad/fablepowers"
printf '[codex]\nimplementer = bad\n' > "$TEST_ROOT/xdg-bad/fablepowers/models.toml"
HOOK_STDIN="$CLAUDE_PAYLOAD" HOOK_ENV="XDG_CONFIG_HOME=$TEST_ROOT/xdg-bad" run_normal "$T"
[[ "$OUT" == "$claude_ref" ]] && pass "Claude Code payload with a malformed models.toml: output unchanged" \
  || fail "Claude Code payload with a malformed models.toml: output changed"

# The parser under bash --posix gives the same output.
RC=0
OUT="$(cd "$TEST_ROOT" && env -u PLUGIN_ROOT XDG_CONFIG_HOME="$CODEX_XDG" "$SH" --posix "$T/hooks/session-start" <"$CODEX_PAYLOAD" 2>"$TEST_ROOT/stderr")" || RC=$?
[[ "$RC" == 0 && "$OUT" == "$codex_reference" ]] && pass "bash --posix: same Codex output with the full models.toml" \
  || fail "bash --posix: rc $RC; $(head -c 160 "$TEST_ROOT/stderr")"
printf '\xef\xbb\xbf[codex]\r\nimplementer = "gpt 6"\r\nreviewer_effort = "x"\r\nfoo = "y"\r\nbar\r\n' > "$TEST_ROOT/xdg-bad/fablepowers/models.toml"
HOOK_STDIN="$CODEX_PAYLOAD" HOOK_ENV="XDG_CONFIG_HOME=$TEST_ROOT/xdg-bad" run_normal "$T"; posix_want="$OUT"
RC=0
OUT="$(cd "$TEST_ROOT" && env -u PLUGIN_ROOT XDG_CONFIG_HOME="$TEST_ROOT/xdg-bad" "$SH" --posix "$T/hooks/session-start" <"$CODEX_PAYLOAD" 2>"$TEST_ROOT/stderr")" || RC=$?
[[ "$RC" == 0 && "$OUT" == "$posix_want" && "$(warnings_of "$OUT")" == "models.toml warnings (4):"* ]] \
  && pass "bash --posix: same Codex output and warnings with a malformed CRLF+BOM models.toml" \
  || fail "bash --posix, malformed file: rc $RC; $(head -c 160 "$TEST_ROOT/stderr")"

# Worst case size: every seat rejected, many warnings, a long config path.
deep="$TEST_ROOT/$(printf 'deep-directory-name-%.0s' {1..8})"
mkdir -p "$deep/fablepowers"
{
  printf '\xef\xbb\xbf[codex]\r\n'
  for k in implementer strict_implementer reviewer; do
    printf '%s = "%s"\r\n' "$k" "$(printf 'x%.0s' {1..80})" "${k}_effort" "nope"
  done
  for i in $(seq 1 200); do printf 'unknown_key_%s_%s = "x"\r\n' "$i" "$(printf 'y%.0s' {1..40})"; done
} > "$deep/fablepowers/models.toml"
HOOK_STDIN="$CODEX_PAYLOAD" HOOK_ENV="XDG_CONFIG_HOME=$deep" run_normal "$T"
size="$(context_of "$OUT" | python3 -c 'import sys; print(len(sys.stdin.read()))')"
nw="$(warnings_of "$OUT" | grep -c '^- ' || true)"
if [[ "$RC" == 0 && "$size" -le 8000 && "$nw" == 4 && "$(seats_of "$OUT")" == "$DEFAULT_SEATS" ]]; then
  pass "worst case (206 warnings, long path): $size characters (cap 8000), 3 warning lines + '… more'"
else
  fail "worst case: rc $RC, $size characters, $nw warning lines, seats '$(seats_of "$OUT")'"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All session-start hook tests passed."
else
  echo "$FAILURES session-start hook test(s) failed."
  exit 1
fi
