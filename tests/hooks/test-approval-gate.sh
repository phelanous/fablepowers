#!/usr/bin/env bash
# Tests for the design-approval gate: hooks/approval-gate (launcher),
# hooks/approval_gate.py, their hooks.json entries, and the user-only
# approve/withdraw skills.
#
# Every gate run goes through the literal "command" string hooks.json holds for
# that event and matcher, with CLAUDE_PLUGIN_ROOT set to a temp plugin tree, via
# "bash -c", with a payload built from tests/hooks/fixtures/gate/*.json (shaped
# on the payloads Claude Code 2.1.299 sent in the gate spike; codex-*.json and
# ups-claude.json on the payloads Codex 0.162.1 and Claude Code sent in the
# codex-port Task 0 run). Placeholders __CWD__, __FILE__, __SUBAGENT__,
# __COMMAND__, __ARGS__, __ANSWER__, __PATCH__, __RESPONSE__, __TASK__,
# __MESSAGE__ and __PROMPT__ are replaced inside JSON strings. Repos are temp
# git repos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/gate"
# Overrides for the files under test (mutation checks on a copy).
HOOKS_JSON="${HOOKS_JSON:-$REPO_ROOT/hooks/hooks.json}"
GATE_LAUNCHER="${GATE_LAUNCHER:-$REPO_ROOT/hooks/approval-gate}"
GATE_PY="${GATE_PY:-$REPO_ROOT/hooks/approval_gate.py}"
SKILLS_DIR="${SKILLS_DIR:-$REPO_ROOT/skills}"
TRUST_SH="${TRUST_SH:-$REPO_ROOT/scripts/codex-hook-trust.sh}"
SH="$BASH"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset FABLEPOWERS_GATE FABLEPOWERS_PYTHON

FAILURES=0
TEST_ROOT="$(mktemp -d)"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

PLUGIN="$TEST_ROOT/plugin"
mkdir -p "$PLUGIN/hooks"
cp "$HOOKS_JSON" "$PLUGIN/hooks/hooks.json"
cp "$GATE_LAUNCHER" "$PLUGIN/hooks/approval-gate"
cp "$GATE_PY" "$PLUGIN/hooks/approval_gate.py"
chmod +x "$PLUGIN/hooks/approval-gate"

# --- helpers ---------------------------------------------------------------------

# hook_cmd <event> <matcher>: the literal command of the one hooks.json entry
# with exactly that matcher ("" = a group without one); exit 1 if there is not
# exactly one such entry.
hook_cmd() {
  python3 - "$PLUGIN/hooks/hooks.json" "$1" "$2" <<'EOF'
import json, sys
entries = [e for e in json.load(open(sys.argv[1]))["hooks"].get(sys.argv[2], []) if e.get("matcher", "") == sys.argv[3]]
if len(entries) != 1 or len(entries[0]["hooks"]) != 1:
    sys.exit(1)
print(entries[0]["hooks"][0]["command"])
EOF
}

# payload <fixture> NAME=value...: the fixture with placeholders __NAME__ replaced,
# on one line with ", " and ": " separators; with PAYLOAD_COMPACT=1, compact JSON
# with no whitespace at all (",", ":"), the shape Claude Code sends.
PAYLOAD_COMPACT=0
payload() {
  PAYLOAD_COMPACT="$PAYLOAD_COMPACT" python3 - "$FIXTURES/$1.json" "${@:2}" <<'EOF'
import json, os, sys
seps = (",", ":") if os.environ.get("PAYLOAD_COMPACT") == "1" else None
subs = dict(a.split("=", 1) for a in sys.argv[2:])
def walk(v):
    if isinstance(v, str):
        for k, s in subs.items():
            v = v.replace("__%s__" % k, s)
        return v
    if isinstance(v, dict):
        return {walk(k): walk(x) for k, x in v.items()}
    if isinstance(v, list):
        return [walk(x) for x in v]
    return v
print(json.dumps(walk(json.load(open(sys.argv[1]))), separators=seps))
EOF
}

# run_gate <event> <matcher> <fixture> NAME=value...: run the hooks.json command
# for that event/matcher on the substituted fixture. stdout -> $OUT, exit -> $RC.
# Extra environment for the hook in the GATE_ENV array; RUN_MODE=broken runs
# with an empty environment and PATH=/nonexistent.
# TMPDIR is pinned to $GATE_TMP so the no-python warn-once markers stay in the
# test tree; reset_warned clears them (every fixture has the same session_id).
GATE_TMP="$TEST_ROOT/tmp"; mkdir -p "$GATE_TMP"
reset_warned() { rm -f "$GATE_TMP"/fablepowers-gate-warned-*; }
GATE_ENV=()
RUN_MODE=normal
run_gate() {
  local event="$1" matcher="$2" fixture="$3" cmd input; shift 3
  if ! cmd="$(hook_cmd "$event" "$matcher")"; then
    OUT=""; RC=99; echo "    (no single hooks.json entry for $event/$matcher)"; return
  fi
  input="$(payload "$fixture" "$@")"
  run_cmd_input "$cmd" "$input"
}

# run_gate_json <event> <matcher> <json>: as run_gate, with a literal payload.
run_gate_json() {
  local cmd
  if ! cmd="$(hook_cmd "$1" "$2")"; then
    OUT=""; RC=99; echo "    (no single hooks.json entry for $1/$2)"; return
  fi
  run_cmd_input "$cmd" "$3"
}

run_cmd_input() {
  local cmd="$1" input="$2"
  RC=0
  if [[ "$RUN_MODE" == broken ]]; then
    OUT="$(cd "$TEST_ROOT" && printf '%s' "$input" | env -i PATH=/nonexistent TMPDIR="$GATE_TMP" CLAUDE_PLUGIN_ROOT="$PLUGIN" ${GATE_ENV[@]+"${GATE_ENV[@]}"} "$SH" -c "$cmd" 2>"$TEST_ROOT/stderr")" || RC=$?
  else
    OUT="$(cd "$TEST_ROOT" && printf '%s' "$input" | env -u BASH TMPDIR="$GATE_TMP" CLAUDE_PLUGIN_ROOT="$PLUGIN" ${GATE_ENV[@]+"${GATE_ENV[@]}"} "$SH" -c "$cmd" 2>"$TEST_ROOT/stderr")" || RC=$?
  fi
}

# verdict: classify $OUT/$RC. deny = exit 0 + exactly the PreToolUse deny shape
# with a non-empty reason; allow = exit 0 + empty stdout; block = exit 0 +
# top-level decision block with a reason; context = exit 0 + UserPromptExpansion,
# UserPromptSubmit or PostToolUse additionalContext; else "other(...)".
verdict() {
  if [[ "$RC" != 0 ]]; then echo "rc$RC"; return; fi
  if [[ -z "$OUT" ]]; then echo allow; return; fi
  printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    print("other(not json)"); sys.exit()
h = d.get("hookSpecificOutput")
if set(d) == {"hookSpecificOutput"} and h.get("hookEventName") == "PreToolUse" \
        and h.get("permissionDecision") == "deny" and set(h) == {"hookEventName", "permissionDecision", "permissionDecisionReason"} \
        and isinstance(h.get("permissionDecisionReason"), str) and h["permissionDecisionReason"]:
    print("deny")
elif set(d) == {"decision", "reason"} and d["decision"] == "block" and d["reason"]:
    print("block")
elif isinstance(h, dict) and h.get("hookEventName") in ("UserPromptExpansion", "UserPromptSubmit", "PostToolUse") and h.get("additionalContext"):
    print("context")
elif set(d) == {"systemMessage"}:
    print("warning")
else:
    print("other(%s)" % json.dumps(d)[:120])
'
}

# text_of: the deny reason / block reason / context / systemMessage text of
# $OUT, or "" when $OUT is not hook JSON.
text_of() {
  printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read()); h = d.get("hookSpecificOutput") or {}
except (ValueError, AttributeError):
    sys.exit()
print(h.get("permissionDecisionReason") or d.get("reason") or h.get("additionalContext") or d.get("systemMessage") or "")'
}

expect() {  # expect <label> <verdict>
  local got; got="$(verdict)"
  if [[ "$got" == "$2" ]]; then pass "$1: $2"; else fail "$1: expected $2, got $got ($(head -c 200 "$TEST_ROOT/stderr"))"; fi
}

new_repo() {  # new_repo <dir>: an empty git repo with docs/specs, docs/plans, src
  mkdir -p "$1"
  git -C "$1" init -q
  mkdir -p "$1/docs/specs" "$1/docs/plans" "$1/src"
  printf 'hello\n' > "$1/src/app.py"
}

# create_spec <repo> <spec-relpath> [cwd]: write the spec file, then run the
# PostToolUse Write create hook for it.
create_spec() {
  local repo="$1" rel="$2" cwd="${3:-$1}"
  mkdir -p "$(dirname "$repo/$rel")"
  printf '# spec\n' > "$repo/$rel"
  run_gate PostToolUse Write post-write-create CWD="$cwd" FILE="$repo/$rel"
}

edit_verdict() {  # edit_verdict <tool-fixture> <repo> <path> [cwd]: verdict of a PreToolUse edit
  local tool
  case "$1" in pre-write) tool=Write ;; pre-edit) tool=Edit ;; pre-multiedit) tool=MultiEdit ;; pre-notebookedit) tool=NotebookEdit ;; esac
  run_gate PreToolUse "$tool" "$1" CWD="${4:-$2}" FILE="$3"
  verdict
}

agent_verdict() {  # agent_verdict <repo> <subagent_type>
  run_gate PreToolUse Agent pre-agent CWD="$1" SUBAGENT="$2"
  verdict
}

json_field() {  # json_field <file> <field>: the field as JSON
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2], "<absent>")))' "$1" "$2"
}

# --- hooks.json wiring --------------------------------------------------------------

echo "hooks.json wiring"

for em in PreToolUse:Agent PreToolUse:Write PreToolUse:Edit PreToolUse:MultiEdit PreToolUse:NotebookEdit \
          PostToolUse:Write PostToolUse:AskUserQuestion \
          UserPromptExpansion:fablepowers:approve UserPromptExpansion:fablepowers:withdraw; do
  event="${em%%:*}"; matcher="${em#*:}"
  if c="$(hook_cmd "$event" "$matcher")" && [[ "$c" == *'${CLAUDE_PLUGIN_ROOT}/hooks/approval-gate'* ]]; then
    pass "$event matcher '$matcher' runs the approval-gate launcher"
  else
    fail "$event matcher '$matcher': no single entry running the approval-gate launcher"
  fi
done

# --- 1. inert with no markers --------------------------------------------------------

echo "1. No markers: inert"

R="$TEST_ROOT/r1"; new_repo "$R"
check "implementer dispatch allowed" test "$(agent_verdict "$R" fablepowers:implementer)" == allow
check "code edit allowed" test "$(edit_verdict pre-edit "$R" "$R/src/app.py")" == allow
check "no .fablepowers created by PreToolUse" test ! -e "$R/.fablepowers"
NR="$TEST_ROOT/not-a-repo"; mkdir -p "$NR/docs/specs"
create_spec "$NR" docs/specs/x.md
expect "outside a git repo, spec create" allow
check "outside a git repo: no marker" test ! -e "$NR/.fablepowers"

# --- 2. spec create -> pending ---------------------------------------------------------

echo "2. Spec create writes pending"

R="$TEST_ROOT/r2"; new_repo "$R"
create_spec "$R" docs/specs/2026-01-01-feat.md
expect "spec create" context
P="$R/.fablepowers/2026-01-01-feat/pending"
check "pending marker written" test -f "$P"
check "pending.spec is the repo-relative path" test "$(json_field "$P" spec)" == '"docs/specs/2026-01-01-feat.md"'
check "pending.created is ISO 8601" python3 -c '
import json,sys,datetime; datetime.datetime.fromisoformat(json.load(open(sys.argv[1]))["created"])' "$P"
check "pending has exactly spec and created" python3 -c '
import json,sys; sys.exit(set(json.load(open(sys.argv[1]))) != {"spec","created"})' "$P"
check ".fablepowers/.gitignore is '*'" test "$(cat "$R/.fablepowers/.gitignore")" == '*'
check "no approved marker" test ! -e "$R/.fablepowers/2026-01-01-feat/approved"

R="$TEST_ROOT/r2b"; new_repo "$R"
printf '# spec\n' > "$R/docs/specs/over.md"
run_gate PostToolUse Write post-write-update CWD="$R" FILE="$R/docs/specs/over.md"
expect "overwrite (type update) of a spec" allow
check "overwrite does not pend" test ! -e "$R/.fablepowers/over/pending"

R="$TEST_ROOT/r2c"; new_repo "$R"
mkdir -p "$R/.fablepowers/done"
printf '{"spec": "docs/specs/done.md", "approved_at": "2026-01-01T00:00:00+00:00", "via": "command", "spec_sha256": null}' > "$R/.fablepowers/done/approved"
create_spec "$R" docs/specs/done.md
check "create of an already-approved key does not re-pend" test ! -e "$R/.fablepowers/done/pending"

R="$TEST_ROOT/r2d"; new_repo "$R"
mkdir -p "$R/docs/specs"; printf 'x' > "$R/docs/specs/sub.md"
run_gate PostToolUse Write post-write-create-subagent CWD="$R" FILE="$R/docs/specs/sub.md"
check "subagent (agent_id) spec create does not pend" test ! -e "$R/.fablepowers/sub"

R="$TEST_ROOT/r2e"; new_repo "$R"
create_spec "$R" docs/notes.md
check "create outside docs/specs does not pend" test ! -e "$R/.fablepowers"
create_spec "$R" docs/specs/notes.txt
check "non-.md under docs/specs does not pend" test ! -e "$R/.fablepowers"
create_spec "$R" docs/specs/nested/deep.md
check "nested docs/specs/<dir>/x.md does not pend" test ! -e "$R/.fablepowers"

R="$TEST_ROOT/r2f"; new_repo "$R"
mkdir -p "$R/src/pkg"
create_spec "$R" "docs/specs/2026 spaced é.md" "$R/src/pkg"
check "spaces/non-ASCII key, created from a subdirectory cwd" test -f "$R/.fablepowers/2026 spaced é/pending"
check "its spec field" test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["spec"])' "$R/.fablepowers/2026 spaced é/pending")" == "docs/specs/2026 spaced é.md"

# --- 3. pending gates dispatch and code edits -------------------------------------------

echo "3. Pending: dispatch and code edits gated"

R="$TEST_ROOT/r3"; new_repo "$R"
create_spec "$R" docs/specs/feat.md
check "implementer dispatch denied" test "$(agent_verdict "$R" fablepowers:implementer)" == deny
agent_verdict "$R" fablepowers:implementer >/dev/null
reason="$(text_of)"
check "deny reason names the spec, both commands and no retry" \
  bash -c '[[ "$1" == *docs/specs/feat.md* && "$1" == *"/fablepowers:approve feat"* && "$1" == *"/fablepowers:withdraw feat"* && "$1" == *"Do not retry"* ]]' _ "$reason"
check "strict-implementer dispatch denied" test "$(agent_verdict "$R" fablepowers:strict-implementer)" == deny
check "reviewer dispatch allowed" test "$(agent_verdict "$R" fablepowers:reviewer)" == allow
check "general-purpose dispatch allowed" test "$(agent_verdict "$R" general-purpose)" == allow
for t in pre-write pre-edit pre-multiedit; do
  check "$t src/app.py denied" test "$(edit_verdict $t "$R" "$R/src/app.py")" == deny
done
check "pre-notebookedit src/nb.ipynb (notebook_path) denied" test "$(edit_verdict pre-notebookedit "$R" "$R/src/nb.ipynb")" == deny
check "relative code path denied" test "$(edit_verdict pre-edit "$R" src/app.py)" == deny
check "README at toplevel denied" test "$(edit_verdict pre-write "$R" "$R/README.md")" == deny
check "docs/specs edit allowed" test "$(edit_verdict pre-edit "$R" "$R/docs/specs/feat.md")" == allow
check "docs/plans write allowed" test "$(edit_verdict pre-write "$R" "$R/docs/plans/feat.md")" == allow
check ".fablepowers/feat/progress.md write allowed" test "$(edit_verdict pre-write "$R" "$R/.fablepowers/feat/progress.md")" == allow
check "notebook in docs/plans allowed" test "$(edit_verdict pre-notebookedit "$R" "$R/docs/plans/n.ipynb")" == allow
check "path outside toplevel allowed" test "$(edit_verdict pre-write "$R" "$TEST_ROOT/elsewhere/x.py")" == allow
check "docs/specsX (prefix, not the dir) denied" test "$(edit_verdict pre-write "$R" "$R/docs/specsX/a.md")" == deny
check ".. traversal out of docs/specs denied" test "$(edit_verdict pre-write "$R" "$R/docs/specs/../../src/app.py")" == deny
ln -s ../../src "$R/docs/plans/srclink"
check "symlink from docs/plans to src denied" test "$(edit_verdict pre-write "$R" "$R/docs/plans/srclink/app.py")" == deny
mkdir -p "$R/src/deep"
check "edit from a subdirectory cwd denied" test "$(edit_verdict pre-edit "$R" "$R/src/app.py" "$R/src/deep")" == deny
check "dispatch from a subdirectory cwd denied" test "$(agent_verdict "$R/src/deep" fablepowers:implementer)" == deny

# Linked worktree: markers live in that worktree's own toplevel.
R="$TEST_ROOT/r3w"; new_repo "$R"
git -C "$R" commit -q --allow-empty -m init
git -C "$R" worktree add -q "$TEST_ROOT/r3w-wt" -b wt
W="$TEST_ROOT/r3w-wt"; mkdir -p "$W/src/sub"
create_spec "$W" docs/specs/wtfeat.md "$W/src/sub"
check "linked worktree: pending in the worktree's .fablepowers" test -f "$W/.fablepowers/wtfeat/pending"
check "linked worktree: code edit denied" test "$(edit_verdict pre-edit "$W" "$W/src/app.py" "$W/src/sub")" == deny
check "main checkout unaffected" test "$(agent_verdict "$R" fablepowers:implementer)" == allow

# --- 4. approved -> quiet ---------------------------------------------------------------

echo "4. Approved: gate quiet"

R="$TEST_ROOT/r4"; new_repo "$R"
create_spec "$R" docs/specs/feat.md
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS=""
check "implementer dispatch allowed" test "$(agent_verdict "$R" fablepowers:implementer)" == allow
check "strict-implementer dispatch allowed" test "$(agent_verdict "$R" fablepowers:strict-implementer)" == allow
check "code edit allowed" test "$(edit_verdict pre-edit "$R" "$R/src/app.py")" == allow
check "spec amendment allowed" test "$(edit_verdict pre-edit "$R" "$R/docs/specs/feat.md")" == allow
run_gate PostToolUse Write post-write-update CWD="$R" FILE="$R/docs/specs/feat.md"
check "spec rewrite after approval keeps it approved" test "$(agent_verdict "$R" fablepowers:implementer)" == allow

R="$TEST_ROOT/r4b"; new_repo "$R"
create_spec "$R" docs/specs/a.md
create_spec "$R" docs/specs/b.md
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS=a
check "two pending, one approved: dispatch still denied" test "$(agent_verdict "$R" fablepowers:implementer)" == deny
check "two pending, one approved: code edit still denied" test "$(edit_verdict pre-edit "$R" "$R/src/app.py")" == deny

# --- 5. marker writes via edit tools denied always ------------------------------------------

echo "5. Marker writes denied always"

R="$TEST_ROOT/r5"; new_repo "$R"
for t in pre-write pre-edit pre-multiedit pre-notebookedit; do
  check "no pending: $t .fablepowers/k/approved denied" test "$(edit_verdict $t "$R" "$R/.fablepowers/k/approved")" == deny
done
check "no pending: Write .fablepowers/k/pending denied" test "$(edit_verdict pre-write "$R" "$R/.fablepowers/k/pending")" == deny
check "relative marker path denied" test "$(edit_verdict pre-write "$R" .fablepowers/k/approved)" == deny
check "marker in another repo's .fablepowers denied" test "$(edit_verdict pre-write "$R" "$TEST_ROOT/other/.fablepowers/k/approved")" == deny
check ".fablepowers/k/approved.md is not a marker" test "$(edit_verdict pre-write "$R" "$R/.fablepowers/k/approved.md")" == allow
mkdir -p "$R/.fablepowers/k"; ln -s "$R/.fablepowers/k/approved" "$R/docs/plans/alias"
check "symlink resolving to a marker denied" test "$(edit_verdict pre-write "$R" "$R/docs/plans/alias")" == deny
create_spec "$R" docs/specs/k2.md
check "pending: Write .fablepowers/k2/approved denied" test "$(edit_verdict pre-write "$R" "$R/.fablepowers/k2/approved")" == deny
run_gate PreToolUse Write pre-write CWD="$R" FILE="$R/.fablepowers/k2/approved"
reason="$(text_of)"
check "marker deny reason points at the commands" bash -c '[[ "$1" == *"/fablepowers:approve"* && "$1" == *"Do not retry"* ]]' _ "$reason"

# --- 5b. marker forgery: directories, case variants, invalid markers ---------------------------

echo "5b. Marker forgery rejected"

R="$TEST_ROOT/r5b"; new_repo "$R"
# Paths through a marker-named directory would create a directory `approved`/`pending`.
for f in .fablepowers/k/approved/x .fablepowers/k/pending/x .fablepowers/k/approved/sub/y.md; do
  check "no pending: Write $f denied" test "$(edit_verdict pre-write "$R" "$R/$f")" == deny
done
check "relative .fablepowers/k/approved/x denied" test "$(edit_verdict pre-write "$R" .fablepowers/k/approved/x)" == deny
# Case variants resolve to the marker on case-insensitive filesystems (payload only).
for f in .fablepowers/k/Approved .fablepowers/k/PENDING .FablePowers/k/approved .FABLEPOWERS/k/Pending/x; do
  check "no pending: Write $f denied" test "$(edit_verdict pre-write "$R" "$R/$f")" == deny
done
check "Edit .FablePowers/k/APPROVED denied" test "$(edit_verdict pre-edit "$R" "$R/.FablePowers/k/APPROVED")" == deny
# Non-marker names under .fablepowers stay writable.
check ".fablepowers/k/reports/pending-review.md allowed" test "$(edit_verdict pre-write "$R" "$R/.fablepowers/k/reports/pending-review.md")" == allow
check ".FablePowers/k/Approved.md allowed" test "$(edit_verdict pre-write "$R" "$R/.FablePowers/k/Approved.md")" == allow
check "src/approved/x.py (no .fablepowers) allowed" test "$(edit_verdict pre-write "$R" "$R/src/approved/x.py")" == allow
create_spec "$R" docs/specs/k3.md
check "pending: Write .fablepowers/k3/approved/x denied" test "$(edit_verdict pre-write "$R" "$R/.fablepowers/k3/approved/x")" == deny
check "pending: Write .FablePowers/k3/Approved denied" test "$(edit_verdict pre-write "$R" "$R/.FablePowers/k3/Approved")" == deny

# An `approved` that the gate did not write does not approve: the design stays pending.
forged_case() {  # forged_case <label> <setup-command...>: pending design f + forged approved
  local R="$TEST_ROOT/r5f-$((++FORGED_N))"; new_repo "$R"
  create_spec "$R" docs/specs/f.md
  ( cd "$R/.fablepowers/f" && "$@" )
  check "forged approved ($LABEL): implementer dispatch denied" test "$(agent_verdict "$R" fablepowers:implementer)" == deny
  check "forged approved ($LABEL): code edit denied" test "$(edit_verdict pre-edit "$R" "$R/src/app.py")" == deny
  check "forged approved ($LABEL): logged to gate.log" grep -q "invalid approved marker for \`f\`" "$R/.fablepowers/gate.log"
}
FORGED_N=0
VALID='{"spec": "docs/specs/f.md", "approved_at": "2026-01-01T00:00:00+00:00", "via": "command", "spec_sha256": null}'
LABEL="directory";            forged_case mkdir -p approved/x
LABEL="empty file";           forged_case touch approved
LABEL="not JSON";             forged_case sh -c 'printf "yes" > approved'
LABEL="JSON array";           forged_case sh -c 'printf "[]" > approved'
LABEL="{} (no fields)";       forged_case sh -c 'printf "{}" > approved'
LABEL="no via";               forged_case sh -c 'printf "%s" "{\"spec\": null, \"approved_at\": \"2026-01-01\"}" > approved'
LABEL="via not a gate path";  forged_case sh -c 'printf "%s" "{\"spec\": null, \"approved_at\": \"2026-01-01\", \"via\": \"model\"}" > approved'
LABEL="no approved_at";       forged_case sh -c 'printf "%s" "{\"spec\": null, \"via\": \"command\"}" > approved'
LABEL="empty approved_at";    forged_case sh -c 'printf "%s" "{\"spec\": null, \"approved_at\": \"\", \"via\": \"command\"}" > approved'
LABEL="no spec";              forged_case sh -c 'printf "%s" "{\"approved_at\": \"2026-01-01\", \"via\": \"command\"}" > approved'
LABEL="spec not a string";    forged_case sh -c 'printf "%s" "{\"spec\": 1, \"approved_at\": \"2026-01-01\", \"via\": \"command\"}" > approved'
LABEL="symlink to valid JSON"; forged_case sh -c 'printf "%s" "$1" > ../real-approval; ln -s ../real-approval approved' _ "$VALID"

R="$TEST_ROOT/r5v"; new_repo "$R"
create_spec "$R" docs/specs/f.md
printf '%s' "$VALID" > "$R/.fablepowers/f/approved"
check "hand-written valid approved JSON (regular file) approves" test "$(agent_verdict "$R" fablepowers:implementer)" == allow
printf '%s' '{"spec": "docs/specs/f.md", "approved_at": "2026-01-01T00:00:00+00:00", "via": "question"}' > "$R/.fablepowers/f/approved"
check "via question, spec_sha256 absent: approves" test "$(agent_verdict "$R" fablepowers:implementer)" == allow

# `pending` counts only as a regular, non-symlink file.
R="$TEST_ROOT/r5p"; new_repo "$R"
mkdir -p "$R/.fablepowers/d/pending"
check "pending as a directory: not pending (dispatch allowed)" test "$(agent_verdict "$R" fablepowers:implementer)" == allow
R="$TEST_ROOT/r5q"; new_repo "$R"
mkdir -p "$R/.fablepowers/s"; printf '{"spec": "docs/specs/s.md"}' > "$R/real-pending"
ln -s "$R/real-pending" "$R/.fablepowers/s/pending"
check "pending as a symlink: not pending (dispatch allowed)" test "$(agent_verdict "$R" fablepowers:implementer)" == allow

# A forged approved directory present before the spec create does not stop it pending.
R="$TEST_ROOT/r5c"; new_repo "$R"
mkdir -p "$R/.fablepowers/pre/approved/x"
create_spec "$R" docs/specs/pre.md
check "forged approved dir before create: pending written" test -f "$R/.fablepowers/pre/pending"
check "forged approved dir before create: dispatch denied" test "$(agent_verdict "$R" fablepowers:implementer)" == deny

# --- 5c. NTFS name variants of markers (path strings only) ------------------------------------

echo "5c. NTFS marker name variants denied"

# NTFS opens `approved.`, `approved ` and `approved:stream` as `approved` (trailing
# dots/spaces are stripped; `:` names an alternate data stream), and likewise for
# the `.fablepowers` directory component.
R="$TEST_ROOT/r5n"; new_repo "$R"
for f in '.fablepowers/k/approved.' '.fablepowers/k/approved ' '.fablepowers/k/approved. . ' \
         '.fablepowers/k/approved:stream' '.fablepowers/k/approved::$DATA' '.fablepowers/k/Pending:x:$DATA' \
         '.fablepowers/k/pending..' '.fablepowers/k/approved./x' '.fablepowers/k/approved.:s' '.fablepowers/k/pending :$DATA' \
         '.fablepowers./k/approved' '.fablepowers /k/approved' '.FablePowers. /k/Approved.'; do
  check "no pending: Write '$f' denied" test "$(edit_verdict pre-write "$R" "$R/$f")" == deny
done
check "relative '.fablepowers/k/approved:s' denied" test "$(edit_verdict pre-write "$R" '.fablepowers/k/approved:s')" == deny
check "Edit '.fablepowers/k/pending ' denied" test "$(edit_verdict pre-edit "$R" "$R/.fablepowers/k/pending ")" == deny
# Only trailing dots/spaces and the stream suffix are ignored.
for f in '.fablepowers/k/approved.md' '.fablepowers/k/approvedx' '.fablepowers/k/notes:approved' \
         '.fablepowers/k/.approved' 'src/approved./x.py'; do
  check "'$f' allowed" test "$(edit_verdict pre-write "$R" "$R/$f")" == allow
done
create_spec "$R" docs/specs/k4.md
check "pending: Write '.fablepowers/k4/approved:x' denied" test "$(edit_verdict pre-write "$R" "$R/.fablepowers/k4/approved:x")" == deny

# --- 5d. marker check on the lexical path ------------------------------------------------------

echo "5d. Marker paths through symlinked directories denied"

# When `.fablepowers/<key>` (or `.fablepowers` itself) is a symlink to a
# non-marker directory, the resolved path has no `.fablepowers` component, but a
# write through it still lands where the gate reads `approved`.
R="$TEST_ROOT/r5l"; new_repo "$R"
mkdir -p "$R/docs/plans/elsewhere" "$R/.fablepowers"
ln -s ../docs/plans/elsewhere "$R/.fablepowers/k"
check "no pending: Write .fablepowers/<symlinked key>/approved denied" test "$(edit_verdict pre-write "$R" "$R/.fablepowers/k/approved")" == deny
check "no pending: Edit .fablepowers/<symlinked key>/pending denied" test "$(edit_verdict pre-edit "$R" "$R/.fablepowers/k/pending")" == deny
R="$TEST_ROOT/r5m"; new_repo "$R"
mkdir -p "$R/docs/plans/fp/k"
ln -s docs/plans/fp "$R/.fablepowers"
check "no pending: Write <symlinked .fablepowers>/k/approved denied" test "$(edit_verdict pre-write "$R" "$R/.fablepowers/k/approved")" == deny

# --- 5e. Claude Code settings files while pending ----------------------------------------------

echo "5e. Settings files closed to the edit tools while pending"

R="$TEST_ROOT/r5s"; new_repo "$R"
H="$TEST_ROOT/home"; mkdir -p "$H/.claude"
check "no pending: Write ~/.claude/settings.json allowed" test "$(edit_verdict pre-write "$R" "$H/.claude/settings.json")" == allow
check "no pending: Write <repo>/.claude/settings.json allowed" test "$(edit_verdict pre-write "$R" "$R/.claude/settings.json")" == allow
create_spec "$R" docs/specs/s.md
check "pending: Write ~/.claude/settings.json denied" test "$(edit_verdict pre-write "$R" "$H/.claude/settings.json")" == deny
run_gate PreToolUse Write pre-write CWD="$R" FILE="$H/.claude/settings.json"
check "settings deny reason names the pending design and the commands" \
  bash -c '[[ "$1" == *docs/specs/s.md* && "$1" == *"/fablepowers:approve s"* && "$1" == *settings.json* && "$1" == *"Do not retry"* ]]' _ "$(text_of)"
check "settings deny reason says the user can make the change themselves" \
  bash -c '[[ "$1" == *"they can make it themselves"* ]]' _ "$(text_of)"
check "pending: Edit ~/.claude/settings.local.json denied" test "$(edit_verdict pre-edit "$R" "$H/.claude/settings.local.json")" == deny
check "pending: MultiEdit <repo>/.claude/settings.json denied" test "$(edit_verdict pre-multiedit "$R" "$R/.claude/settings.json")" == deny
check "pending: <repo>/docs/plans/.claude/settings.json denied (allowed dir)" test "$(edit_verdict pre-write "$R" "$R/docs/plans/.claude/settings.json")" == deny
check "pending: relative .claude/settings.local.json from cwd docs/plans denied" \
  test "$(edit_verdict pre-write "$R" .claude/settings.local.json "$R/docs/plans")" == deny
for f in .Claude/Settings.JSON .CLAUDE/settings.local.json '.claude/settings.json.' '.claude/settings.json ' \
         '.claude/settings.json:s' '.claude./settings.json'; do
  check "pending: Write ~/'$f' denied" test "$(edit_verdict pre-write "$R" "$H/$f")" == deny
done
# A settings file reached through a symlinked directory (resolved path matches).
ln -s "$H/.claude" "$TEST_ROOT/cfglink"
check "pending: Write <symlink to ~/.claude>/settings.json denied" test "$(edit_verdict pre-write "$R" "$TEST_ROOT/cfglink/settings.json")" == deny
# A settings file that is itself a symlink into a dotfiles tree (lexical path matches).
D="$TEST_ROOT/home2"; mkdir -p "$D/.claude" "$TEST_ROOT/dotfiles"; printf '{}' > "$TEST_ROOT/dotfiles/claude-settings"
ln -s "$TEST_ROOT/dotfiles/claude-settings" "$D/.claude/settings.json"
check "pending: Write ~/.claude/settings.json symlinked to dotfiles denied" test "$(edit_verdict pre-write "$R" "$D/.claude/settings.json")" == deny
for f in .claude/settings.json.bak .claude/agents/x.md claude/settings.json .claude/hooks/settings.json .claude/settings.yaml; do
  check "pending: Write ~/'$f' (not a settings file) allowed" test "$(edit_verdict pre-write "$R" "$H/$f")" == allow
done
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS=""
check "approved: Write ~/.claude/settings.json allowed" test "$(edit_verdict pre-write "$R" "$H/.claude/settings.json")" == allow

# --- 6. approve and withdraw commands ---------------------------------------------------------

echo "6. Approve / withdraw commands"

R="$TEST_ROOT/r6"; new_repo "$R"
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS=""
expect "nothing pending" context
check "nothing pending: says so" bash -c '[[ "$1" == *"nothing is pending"* ]]' _ "$(text_of)"
check "nothing pending: no marker" test ! -e "$R/.fablepowers"

create_spec "$R" docs/specs/one.md
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS=""
expect "one pending, no arg" context
A="$R/.fablepowers/one/approved"
check "approved written" test -f "$A"
check "approved.via == command" test "$(json_field "$A" via)" == '"command"'
check "approved.spec" test "$(json_field "$A" spec)" == '"docs/specs/one.md"'
check "approved.spec_sha256 matches the spec" test "$(json_field "$A" spec_sha256)" == "\"$(sha256sum "$R/docs/specs/one.md" | cut -d' ' -f1)\""
check "approved.approved_at is ISO 8601" python3 -c '
import json,sys,datetime; datetime.datetime.fromisoformat(json.load(open(sys.argv[1]))["approved_at"])' "$A"
check "approved has exactly its four fields" python3 -c '
import json,sys; sys.exit(set(json.load(open(sys.argv[1]))) != {"spec","approved_at","via","spec_sha256"})' "$A"
check "pending kept for audit" test -f "$R/.fablepowers/one/pending"

R="$TEST_ROOT/r6b"; new_repo "$R"
create_spec "$R" docs/specs/gone.md; rm "$R/docs/specs/gone.md"
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS=""
check "spec missing: approved with spec_sha256 null" test "$(json_field "$R/.fablepowers/gone/approved" spec_sha256)" == null

R="$TEST_ROOT/r6c"; new_repo "$R"
create_spec "$R" docs/specs/one.md
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS="nope"
expect "one pending, unknown arg" block
check "unknown arg: nothing written" test ! -e "$R/.fablepowers/one/approved"
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS="docs/specs/one.md"
check "one pending, spec path arg: approved" test -f "$R/.fablepowers/one/approved"

R="$TEST_ROOT/r6d"; new_repo "$R"
create_spec "$R" docs/specs/a.md
create_spec "$R" docs/specs/b.md
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS=""
expect "several pending, no arg" block
check "block lists both keys" bash -c '[[ "$1" == *"a (docs/specs/a.md)"* && "$1" == *"b (docs/specs/b.md)"* ]]' _ "$(text_of)"
check "several, no arg: nothing written" test ! -e "$R/.fablepowers/a/approved" -a ! -e "$R/.fablepowers/b/approved"
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS="zzz"
expect "several pending, unknown arg" block
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS=" b "
expect "several pending, key b" context
check "only b approved" test -f "$R/.fablepowers/b/approved" -a ! -e "$R/.fablepowers/a/approved"

run_gate UserPromptExpansion fablepowers:withdraw expansion CWD="$R" COMMAND=fablepowers:withdraw ARGS=""
expect "withdraw, one pending (a), no arg" context
check "withdraw removes a/pending" test ! -e "$R/.fablepowers/a/pending"
check "withdraw leaves the spec and b's markers" test -f "$R/docs/specs/a.md" -a -f "$R/.fablepowers/b/pending" -a -f "$R/.fablepowers/b/approved"
check "after withdraw: dispatch allowed" test "$(agent_verdict "$R" fablepowers:implementer)" == allow

R="$TEST_ROOT/r6e"; new_repo "$R"
create_spec "$R" docs/specs/a.md
create_spec "$R" docs/specs/b.md
run_gate UserPromptExpansion fablepowers:withdraw expansion CWD="$R" COMMAND=fablepowers:withdraw ARGS=""
expect "withdraw, several pending, no arg" block
check "withdraw blocked: both still pending" test -f "$R/.fablepowers/a/pending" -a -f "$R/.fablepowers/b/pending"
run_gate UserPromptExpansion fablepowers:withdraw expansion CWD="$R" COMMAND=fablepowers:withdraw ARGS="a.md"
check "withdraw a.md: only a removed, nothing approved" test ! -e "$R/.fablepowers/a/pending" -a -f "$R/.fablepowers/b/pending" -a ! -e "$R/.fablepowers/a/approved"
run_gate UserPromptExpansion fablepowers:withdraw expansion CWD="$R" COMMAND=fablepowers:withdraw ARGS="b"
run_gate UserPromptExpansion fablepowers:withdraw expansion CWD="$R" COMMAND=fablepowers:withdraw ARGS=""
expect "withdraw, nothing pending" context

R="$TEST_ROOT/r6f"; new_repo "$R"
create_spec "$R" docs/specs/one.md
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:other ARGS=""
expect "other command name" allow
check "other command: nothing approved" test ! -e "$R/.fablepowers/one/approved"

# --- 7. question path -----------------------------------------------------------------------

echo "7. Approval question path"

R="$TEST_ROOT/r7"; new_repo "$R"
create_spec "$R" docs/specs/q.md
run_gate PostToolUse AskUserQuestion post-ask CWD="$R" ANSWER="Changes needed"
expect "Changes needed" allow
check "Changes needed: not approved" test ! -e "$R/.fablepowers/q/approved"
run_gate PostToolUse AskUserQuestion post-ask-other-labels CWD="$R"
expect "different labels answered Approve" allow
check "different labels: not approved" test ! -e "$R/.fablepowers/q/approved"
run_gate PostToolUse AskUserQuestion post-ask-three-options CWD="$R"
expect "three options (Approve, Changes needed twice) answered Approve" allow
check "three options: not approved" test ! -e "$R/.fablepowers/q/approved"
run_gate PostToolUse AskUserQuestion post-ask-unanswered CWD="$R"
expect "empty answers" allow
check "empty answers: not approved" test ! -e "$R/.fablepowers/q/approved"
run_gate PostToolUse AskUserQuestion post-ask CWD="$R" ANSWER="Approve"
expect "Approve, exact labels, one pending" context
check "approved.via == question" test "$(json_field "$R/.fablepowers/q/approved" via)" == '"question"'
check "question approval opens the gate" test "$(agent_verdict "$R" fablepowers:implementer)" == allow

R="$TEST_ROOT/r7b"; new_repo "$R"
create_spec "$R" docs/specs/a.md
create_spec "$R" docs/specs/b.md
run_gate PostToolUse AskUserQuestion post-ask CWD="$R" ANSWER="Approve"
check "two pending: nothing approved" test ! -e "$R/.fablepowers/a/approved" -a ! -e "$R/.fablepowers/b/approved"
check "two pending: systemMessage and context name the keys and the command" python3 -c '
import json,sys
d = json.loads(sys.argv[1]); s = d["systemMessage"]; c = d["hookSpecificOutput"]["additionalContext"]
assert d["hookSpecificOutput"]["hookEventName"] == "PostToolUse"
for t in (s, c):
    assert "a (docs/specs/a.md)" in t and "b (docs/specs/b.md)" in t and "/fablepowers:approve" in t, t
' "$OUT"

R="$TEST_ROOT/r7c"; new_repo "$R"
create_spec "$R" docs/specs/gone.md; rm "$R/docs/specs/gone.md"
run_gate PostToolUse AskUserQuestion post-ask CWD="$R" ANSWER="Approve"
check "spec gone: not approved" test ! -e "$R/.fablepowers/gone/approved"
check "spec gone: tells the user to run /fablepowers:approve gone" bash -c '[[ "$1" == *"/fablepowers:approve gone"* ]]' _ "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["systemMessage"])')"

R="$TEST_ROOT/r7d"; new_repo "$R"
run_gate PostToolUse AskUserQuestion post-ask CWD="$R" ANSWER="Approve"
check "no pending: nothing written" test ! -e "$R/.fablepowers"

# --- 8. escape hatch and python3 detection -------------------------------------------------------

echo "8. FABLEPOWERS_GATE=off and python3 detection"

R="$TEST_ROOT/r8"; new_repo "$R"
create_spec "$R" docs/specs/feat.md
GATE_ENV=(FABLEPOWERS_GATE=off)
check "off: implementer dispatch allowed" test "$(agent_verdict "$R" fablepowers:implementer)" == allow
check "off: code edit allowed" test "$(edit_verdict pre-edit "$R" "$R/src/app.py")" == allow
check "off: marker write allowed" test "$(edit_verdict pre-write "$R" "$R/.fablepowers/feat/approved")" == allow
GATE_ENV=()
check "off: gate.log has the would-be denials" test "$(grep -c 'would deny' "$R/.fablepowers/gate.log")" == 3
check "off: gate.log names the dispatch" grep -q 'would deny Agent' "$R/.fablepowers/gate.log"

run_gate PreToolUse Agent pre-agent CWD="$R" SUBAGENT=fablepowers:implementer
before="$OUT"
RUN_MODE=broken
run_gate PreToolUse Agent pre-agent CWD="$R" SUBAGENT=fablepowers:implementer
expect "broken PATH (fallback python): dispatch" deny
check "broken PATH output equals normal" test "$OUT" == "$before"
RUN_MODE=normal

printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/brokenpy"; chmod +x "$TEST_ROOT/brokenpy"
WARNING='{"systemMessage":"fablepowers approval gate disabled: python3 not found"}'
WARNED="$GATE_TMP/fablepowers-gate-warned-$UID-76496df1-bffc-49e9-96ae-c92ee405caf7"
# No usable python: silent outside git; in a repo without .fablepowers/ silent
# except on the calls where the gate would have acted (spec create, the
# approval question, approve/withdraw), where it warns once per session; in a
# repo with .fablepowers/ it warns once per session on any call.
for py in /nonexistent "$TEST_ROOT/brokenpy" "$TEST_ROOT"; do
  GATE_ENV=("FABLEPOWERS_PYTHON=$py")
  run_gate PreToolUse Agent pre-agent CWD="$TEST_ROOT/nowhere" SUBAGENT=fablepowers:implementer
  expect "FABLEPOWERS_PYTHON=$py, outside git: silent" allow
done
mkdir -p "$TEST_ROOT/nowhere/docs/specs"
run_gate PostToolUse Write post-write-create CWD="$TEST_ROOT/nowhere" FILE="$TEST_ROOT/nowhere/docs/specs/a.md"
expect "no python, outside git: spec create silent" allow
run_gate PostToolUse AskUserQuestion post-ask CWD="$TEST_ROOT/nowhere" ANSWER=Approve
expect "no python, outside git: approval answer silent" allow
check "  no warn-once marker" test ! -e "$WARNED"

# nopy_gate_events <label> <repo>: the no-python checks for a repo or worktree
# without .fablepowers/ (GATE_ENV must select a missing python).
nopy_gate_events() {
  local L="$1" R="$2"
  reset_warned
  run_gate PreToolUse Agent pre-agent CWD="$R" SUBAGENT=fablepowers:implementer
  expect "no python, $L: implementer dispatch silent" allow
  run_gate PreToolUse Write pre-write CWD="$R" FILE="$R/docs/specs/a.md"
  expect "no python, $L: PreToolUse Write of a spec silent" allow
  run_gate PostToolUse Write post-write-create CWD="$R" FILE="$R/src/new.py"
  expect "no python, $L: non-spec create silent" allow
  run_gate PostToolUse Write post-write-create CWD="$R" FILE="$R/docs/specs/notes.txt"
  expect "no python, $L: non-.md create under docs/specs silent" allow
  run_gate PostToolUse Write post-write-update CWD="$R" FILE="$R/docs/specs/a.md"
  expect "no python, $L: spec update silent" allow
  run_gate PostToolUse Write post-write-create CWD="$R" FILE="$R/src/docs/specsx/a.md"
  expect "no python, $L: create under a docs/specs-like path silent" allow
  run_gate_json PostToolUse Write "$(payload post-write-create CWD="$R" FILE="$R/docs/specs/a.md" | sed 's/"PostToolUse"/"PreToolUse"/')"
  expect "no python, $L: spec-create-shaped PreToolUse payload silent" allow
  check "  $L: no warn-once marker yet" test ! -e "$WARNED"
  run_gate PostToolUse Write post-write-create CWD="$R" FILE="$R/docs/specs/a.md"
  expect "no python, $L: spec create warns" warning
  check "  $L: warning text" test "$OUT" == "$WARNING"
  check "  $L: warn-once marker in TMPDIR" test -f "$WARNED"
  check "  $L: no .fablepowers/ created" test ! -e "$R/.fablepowers"
  run_gate PostToolUse AskUserQuestion post-ask CWD="$R" ANSWER=Approve
  expect "no python, $L: approval answer after the warning silent" allow
  run_gate PostToolUse Write post-write-create CWD="$R" FILE="$R/docs/specs/b.md"
  expect "no python, $L: second spec create silent" allow
  reset_warned
  run_gate PostToolUse AskUserQuestion post-ask CWD="$R" ANSWER=Approve
  expect "no python, $L: PostToolUse AskUserQuestion warns" warning
  run_gate PostToolUse AskUserQuestion post-ask CWD="$R" ANSWER=Approve
  expect "no python, $L: PostToolUse AskUserQuestion once per session" allow
  reset_warned
  run_gate_json PostToolUse AskUserQuestion "$(payload post-ask CWD="$R" ANSWER=Approve | sed 's/"PostToolUse"/"PreToolUse"/')"
  expect "no python, $L: PreToolUse AskUserQuestion warns" warning
  reset_warned
  run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=fablepowers:approve ARGS=
  expect "no python, $L: /fablepowers:approve warns" warning
  run_gate UserPromptExpansion fablepowers:withdraw expansion CWD="$R" COMMAND=fablepowers:withdraw ARGS=
  expect "no python, $L: /fablepowers:withdraw once per session" allow
  reset_warned
  run_gate UserPromptExpansion fablepowers:withdraw expansion CWD="$R" COMMAND=fablepowers:withdraw ARGS=a
  expect "no python, $L: /fablepowers:withdraw warns" warning
  reset_warned
  run_gate UserPromptExpansion fablepowers:approve expansion CWD="$R" COMMAND=other:approve ARGS=
  expect "no python, $L: another command's expansion silent" allow
  check "  $L: still no .fablepowers/" test ! -e "$R/.fablepowers"
}
GATE_ENV=("FABLEPOWERS_PYTHON=/nonexistent")
RQ="$TEST_ROOT/r8q"; new_repo "$RQ"
nopy_gate_events "fresh repo without .fablepowers/" "$RQ"
git -C "$RQ" commit -q --allow-empty -m init
git -C "$RQ" worktree add -q "$TEST_ROOT/r8q-wt" -b wt8
mkdir -p "$TEST_ROOT/r8q-wt/docs/specs" "$TEST_ROOT/r8q-wt/src"
mkdir -p "$RQ/.fablepowers"   # the main checkout has one; the worktree does not
nopy_gate_events "linked worktree without .fablepowers/" "$TEST_ROOT/r8q-wt"
# Compact JSON (no whitespace), as Claude Code sends it: the launcher's raw
# payload classification must not depend on spaces around ':'.
PAYLOAD_COMPACT=1
check "compact payloads have no whitespace after ':'" \
  test "$(payload post-ask CWD=/x ANSWER=Approve | grep -c '"tool_name":"AskUserQuestion"')" == 1
RC8="$TEST_ROOT/r8c"; new_repo "$RC8"
nopy_gate_events "compact JSON, fresh repo without .fablepowers/" "$RC8"
PAYLOAD_COMPACT=0
# A payload without session_id warns on every qualifying call.
reset_warned
for n in 1 2; do
  run_gate_json PostToolUse AskUserQuestion "$(payload post-ask CWD="$TEST_ROOT/r8q-wt" ANSWER=Approve | sed 's/"session_id": *"[^"]*",//')"
  expect "no python, no session_id: call $n warns" warning
done
reset_warned
RUN_MODE=broken
run_gate PreToolUse Agent pre-agent CWD="$R" SUBAGENT=fablepowers:implementer
expect "no python, empty PATH, pending design: first call warns (allowed)" warning
check "  warning text" test "$OUT" == "$WARNING"
check "  warn-once marker written" test -e "$WARNED"
run_gate PreToolUse Write pre-write CWD="$R" FILE="$R/src/app.py"
expect "no python, same session: second call silent" allow
RUN_MODE=normal
reset_warned
RF="$TEST_ROOT/r8f"; new_repo "$RF"; mkdir -p "$RF/.fablepowers"
GATE_ENV=("FABLEPOWERS_PYTHON=$TEST_ROOT/brokenpy")
run_gate PreToolUse Write pre-write CWD="$RF/src" FILE="$RF/src/app.py"
expect "broken python, repo with .fablepowers/ (subdirectory cwd): warns" warning
reset_warned
GATE_ENV=("FABLEPOWERS_PYTHON=$(command -v python3)")
check "FABLEPOWERS_PYTHON=<real python3> runs the gate" test "$(agent_verdict "$R" fablepowers:implementer)" == deny
# The core flow with compact payloads through the real python gate.
PAYLOAD_COMPACT=1
RCF="$TEST_ROOT/r8cf"; new_repo "$RCF"
create_spec "$RCF" docs/specs/feat.md
expect "compact JSON: spec create" context
check "  compact JSON: pending written" test -f "$RCF/.fablepowers/feat/pending"
check "compact JSON: implementer dispatch denied while pending" test "$(agent_verdict "$RCF" fablepowers:implementer)" == deny
run_gate UserPromptExpansion fablepowers:approve expansion CWD="$RCF" COMMAND=fablepowers:approve ARGS=""
expect "compact JSON: /fablepowers:approve" context
check "  compact JSON: approved written" test -f "$RCF/.fablepowers/feat/approved"
check "compact JSON: implementer dispatch allowed after approval" test "$(agent_verdict "$RCF" fablepowers:implementer)" == allow
check "compact JSON: code edit allowed after approval" test "$(edit_verdict pre-edit "$RCF" "$RCF/src/app.py")" == allow
PAYLOAD_COMPACT=0
# A python below 3.8 fails the launcher's version check: fake one by making
# sys.version_info's check exit 1 (as "import sys; sys.exit(True)" would).
printf '#!/bin/sh\ncase "$*" in *version_info*) exit 1 ;; esac\nexec python3 "$@"\n' > "$TEST_ROOT/py37"; chmod +x "$TEST_ROOT/py37"
GATE_ENV=("FABLEPOWERS_PYTHON=$TEST_ROOT/py37")
RP="$TEST_ROOT/r8p"; new_repo "$RP"; mkdir -p "$RP/.fablepowers"
reset_warned
run_gate PreToolUse Agent pre-agent CWD="$RP" SUBAGENT=fablepowers:implementer
expect "python failing the 3.8 check" warning
GATE_ENV=()

# Python runs isolated (-I): a PYTHONPATH shadowing a stdlib module is ignored.
mkdir -p "$TEST_ROOT/evil"; printf 'raise SystemExit(7)\n' > "$TEST_ROOT/evil/json.py"
GATE_ENV=("PYTHONPATH=$TEST_ROOT/evil")
check "PYTHONPATH with a shadowing json.py is ignored" test "$(agent_verdict "$R" fablepowers:implementer)" == deny
GATE_ENV=()

# Malformed payloads fail open and are logged.
R="$TEST_ROOT/r8m"; new_repo "$R"
create_spec "$R" docs/specs/feat.md
cmd="$(hook_cmd PreToolUse Agent)" || cmd="exit 98"
RC=0; OUT="$(cd "$R" && printf 'not json' | CLAUDE_PLUGIN_ROOT="$PLUGIN" "$SH" -c "$cmd" 2>"$TEST_ROOT/stderr")" || RC=$?
expect "non-JSON payload" allow
check "  logged to gate.log" grep -q 'malformed hook payload' "$R/.fablepowers/gate.log"
RC=0; OUT="$(cd "$R" && printf '{"hook_event_name":"PreToolUse","tool_name":"Agent","cwd":"%s","tool_input":"x"}' "$R" | CLAUDE_PLUGIN_ROOT="$PLUGIN" "$SH" -c "$cmd" 2>"$TEST_ROOT/stderr")" || RC=$?
expect "tool_input not an object" allow
check "  logged to gate.log" grep -q 'malformed PreToolUse Agent' "$R/.fablepowers/gate.log"

# --- 9. approve/withdraw are user-only ---------------------------------------------------------

echo "9. approve/withdraw frontmatter: disable-model-invocation: true"

for s in approve withdraw; do
  check "skills/$s: disable-model-invocation is true" python3 - "$SKILLS_DIR/$s/SKILL.md" "$s" <<'EOF'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
assert lines[0] == "---"
end = lines.index("---", 1)
fm = {}
for l in lines[1:end]:
    if ":" in l and not l.startswith(" "):
        k, v = l.split(":", 1)
        fm[k.strip()] = v.strip()
sys.exit(not (fm.get("disable-model-invocation") == "true" and fm.get("name") == sys.argv[2]))
EOF
done

# --- 10. deny output shape ----------------------------------------------------------------------

echo "10. Deny output shape"

R="$TEST_ROOT/r10"; new_repo "$R"
create_spec "$R" docs/specs/feat.md
run_gate PreToolUse Edit pre-edit CWD="$R" FILE="$R/src/app.py"
check "exit 0" test "$RC" == 0
check "stdout is exactly {hookSpecificOutput:{hookEventName:PreToolUse, permissionDecision:deny, permissionDecisionReason}}" python3 -c '
import json,sys
d = json.loads(sys.argv[1])
assert list(d) == ["hookSpecificOutput"]
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "PreToolUse" and h["permissionDecision"] == "deny"
assert isinstance(h["permissionDecisionReason"], str) and h["permissionDecisionReason"].strip()
assert len(h) == 3
' "$OUT"
check "nothing on stderr" test ! -s "$TEST_ROOT/stderr"

# --- 11. Codex branch -------------------------------------------------------------------------

echo "11. Codex: hooks.json wiring and skill policy"

check "PreToolUse groups: the 0.4.0 ones first, in order, then the Codex spawns" python3 -c '
import json,sys
h = json.load(open(sys.argv[1]))["hooks"]
m = lambda ev: [g.get("matcher") for g in h[ev]]
assert list(h) == ["SessionStart", "PreToolUse", "PostToolUse", "UserPromptExpansion", "UserPromptSubmit"], list(h)
assert m("PreToolUse") == ["Agent", "Write", "Edit", "MultiEdit", "NotebookEdit", "collaborationspawn_agent", "spawn_agent"], m("PreToolUse")
assert m("PostToolUse") == ["Write", "AskUserQuestion"], m("PostToolUse")
assert m("UserPromptExpansion") == ["fablepowers:approve", "fablepowers:withdraw"]
assert m("UserPromptSubmit") == [None], m("UserPromptSubmit")
' "$PLUGIN/hooks/hooks.json"
for em in PreToolUse:collaborationspawn_agent PreToolUse:spawn_agent; do
  event="${em%%:*}"; matcher="${em#*:}"
  if c="$(hook_cmd "$event" "$matcher")" && [[ "$c" == *'${CLAUDE_PLUGIN_ROOT}/hooks/approval-gate"; done; exec bash'* ]]; then
    pass "$event matcher '$matcher' runs the approval-gate launcher"
  else
    fail "$event matcher '$matcher': no single entry running the approval-gate launcher"
  fi
done
if c="$(hook_cmd UserPromptSubmit "")" && [[ "$c" == *'${CLAUDE_PLUGIN_ROOT}/hooks/approval-gate" ups; done; exec bash "${CLAUDE_PLUGIN_ROOT}/hooks/approval-gate" ups' ]]; then
  pass "UserPromptSubmit group runs the launcher with the 'ups' fast-path argument"
else
  fail "UserPromptSubmit group: no single entry running 'approval-gate ups'"
fi
for s in approve withdraw; do
  check "skills/$s/agents/openai.yaml: allow_implicit_invocation false" \
    test "$(cat "$SKILLS_DIR/$s/agents/openai.yaml" 2>/dev/null)" == $'policy:\n  allow_implicit_invocation: false'
done

# Codex helpers. patch_of <op-lines>: a patch around the lines; resp_of <A|M|D path>...:
# the apply_patch tool_response Codex 0.162.1 prints for a success.
patch_of() { printf '*** Begin Patch\n%s\n*** End Patch' "$1"; }
resp_of() { printf 'Exit code: 0\nWall time: 0.1 seconds\nOutput:\nSuccess. Updated the following files:\n'; printf '%s\n' "$@"; }
CODEX_DENIES="$TEST_ROOT/codex-denies"; : > "$CODEX_DENIES"
# note_deny: record the deny text of $OUT (one per line) for the recovery-line check.
note_deny() { [[ "$(verdict)" == deny ]] && text_of | tr '\n' ' ' >> "$CODEX_DENIES" && echo >> "$CODEX_DENIES"; return 0; }
# cpatch <repo> <patch> [cwd] [matcher]: verdict of a PreToolUse apply_patch.
cpatch() {
  run_gate PreToolUse "${4:-Write}" codex-pre-apply_patch CWD="${3:-$1}" PATCH="$2"
  note_deny; verdict
}
# cspawn2 <repo> <task_name>, cspawn1 <repo> <message> [matcher]: verdict of a spawn.
cspawn2() { run_gate PreToolUse collaborationspawn_agent codex-v2-pre-spawn CWD="$1" TASK="$2"; note_deny; verdict; }
cspawn1() { run_gate PreToolUse "${3:-spawn_agent}" codex-v1-pre-spawn CWD="$1" MESSAGE="$2"; note_deny; verdict; }
# cpost <repo> <patch> <response> [cwd] [fixture]: run a PostToolUse apply_patch.
cpost() { run_gate PostToolUse Write "${5:-codex-post-apply_patch}" CWD="${4:-$1}" PATCH="$2" RESPONSE="$3"; }
# ccreate <repo> <path-from-cwd> [cwd]: write the spec, then its Codex Post Add.
ccreate() {
  local cwd="${3:-$1}"
  mkdir -p "$(dirname "$cwd/$2")"; printf '# spec\n' > "$cwd/$2"
  cpost "$1" "$(patch_of "*** Add File: $2"$'\n+# spec')" "$(resp_of "A $2")" "$cwd"
}
# cups <repo> <prompt> [fixture]: run a UserPromptSubmit.
cups() { run_gate UserPromptSubmit "" "${3:-codex-ups}" CWD="$1" PROMPT="$2"; }

echo "12. Codex: apply_patch spec add -> pending"

R="$TEST_ROOT/c1"; new_repo "$R"
ccreate "$R" docs/specs/2026-01-01-cx.md
expect "v2 Add File docs/specs/*.md" context
P="$R/.fablepowers/2026-01-01-cx/pending"
check "pending written" test -f "$P"
check "pending.spec is the repo-relative path" test "$(json_field "$P" spec)" == '"docs/specs/2026-01-01-cx.md"'
check "pending context names \$fablepowers:approve and no question path" \
  bash -c '[[ "$1" == *'\''`$fablepowers:approve`'\''* && "$1" == *"no approval question"* && "$1" != *"/fablepowers:approve"* ]]' _ "$(text_of)"
cp "$P" "$TEST_ROOT/c1-pending"
ccreate "$R" docs/specs/2026-01-01-cx.md
expect "duplicate Post for the same Add (idempotent)" allow
check "  pending unchanged" cmp -s "$P" "$TEST_ROOT/c1-pending"

R="$TEST_ROOT/c1v1"; new_repo "$R"; printf '# V1\n' > "$R/docs/specs/v1.md"
cpost "$R" "$(patch_of $'*** Add File: docs/specs/v1.md\n+# V1')" "$(resp_of "A docs/specs/v1.md")" "$R" codex-v1-post-apply_patch
expect "v1 Add File docs/specs/v1.md" context
check "  v1: pending written" test -f "$R/.fablepowers/v1/pending"

R="$TEST_ROOT/c1s"; new_repo "$R"; mkdir -p "$R/sub/docs/specs"
ccreate "$R" docs/specs/t0.md "$R/sub"
check "subdirectory cwd: docs/specs/t0.md is <cwd>/docs/specs, not a spec" test ! -e "$R/.fablepowers"
ccreate "$R" ../docs/specs/up.md "$R/sub"
check "subdirectory cwd: ../docs/specs/up.md pends" test -f "$R/.fablepowers/up/pending"
check "  its spec field" test "$(json_field "$R/.fablepowers/up/pending" spec)" == '"docs/specs/up.md"'

R="$TEST_ROOT/c1a"; new_repo "$R"; printf 'x' > "$R/docs/specs/sub.md"
cpost "$R" "$(patch_of $'*** Add File: docs/specs/sub.md\n+x')" "$(resp_of "A docs/specs/sub.md")" "$R" codex-post-apply_patch-subagent
expect "subagent (agent_id) Add of a spec" allow
check "  subagent: no pending" test ! -e "$R/.fablepowers"
cpost "$R" "$(patch_of $'*** Add File: docs/specs/sub.md\n+x')" "Exit code: 1"
check "Add without an 'A <path>' response line (patch failed): no pending" test ! -e "$R/.fablepowers"
cpost "$R" "$(patch_of $'*** Update File: docs/specs/sub.md\n@@\n-x\n+y')" "$(resp_of "M docs/specs/sub.md")"
check "Update of a spec: no pending" test ! -e "$R/.fablepowers"
cpost "$R" "$(patch_of $'*** Add File: docs/notes.md\n+x\n*** Add File: docs/specs/n.txt\n+x\n*** Add File: docs/specs/d/deep.md\n+x')" \
  "$(resp_of "A docs/notes.md" "A docs/specs/n.txt" "A docs/specs/d/deep.md")"
check "Add outside docs/specs, non-.md, nested: no pending" test ! -e "$R/.fablepowers"
cpost "$R" "*** Begin Patch"$'\n'"*** End Patch" "$(resp_of)"
expect "Post with no file operation" allow
check "  logged" grep -q 'PostToolUse Codex apply_patch without a parseable patch' "$R/.fablepowers/gate.log"

R="$TEST_ROOT/c1m"; new_repo "$R"
cpost "$R" "$(patch_of $'*** Add File: docs/plans/p.md\n+p\n*** Add File: docs/specs/m1.md\n+a\n*** Add File: docs/specs/m2.md\n+b')" \
  "$(resp_of "A docs/plans/p.md" "A docs/specs/m1.md" "A docs/specs/m2.md")"
expect "one patch adding two specs" context
check "  both pending" test -f "$R/.fablepowers/m1/pending" -a -f "$R/.fablepowers/m2/pending"
# M1: a trailing-space path and CRLF lines are trimmed, as Codex applies them.
cpost "$R" "$(patch_of $'*** Add File: docs/specs/trail.md   \n+t')" "$(resp_of "A docs/specs/trail.md")"
check "Add path with trailing spaces: pending under the trimmed key" test -f "$R/.fablepowers/trail/pending"
cpost "$R" $'*** Begin Patch\r\n  *** Add File: docs/specs/crlf.md\r\n+c\r\n*** End Patch\r\n' "$(resp_of "A docs/specs/crlf.md")"
check "CRLF patch with an indented Add header: pending" test -f "$R/.fablepowers/crlf/pending"

# S3: Add File overwrites, so on Codex rewriting a marker-less spec re-pends it.
R="$TEST_ROOT/c1o"; new_repo "$R"; printf '# old\n' > "$R/docs/specs/old.md"
cpost "$R" "$(patch_of $'*** Add File: docs/specs/old.md\n+# new')" "$(resp_of "A docs/specs/old.md")"
check "S3: Add File over an existing spec without markers re-pends it" test -f "$R/.fablepowers/old/pending"
mkdir -p "$R/.fablepowers/done"
printf '{"spec": "docs/specs/done.md", "approved_at": "2026-01-01T00:00:00+00:00", "via": "command", "spec_sha256": null}' > "$R/.fablepowers/done/approved"
cpost "$R" "$(patch_of $'*** Add File: docs/specs/done.md\n+# again')" "$(resp_of "A docs/specs/done.md")"
check "Add of an already approved key does not re-pend" test ! -e "$R/.fablepowers/done/pending"

# S2: a spec created by moving a file into docs/specs/ (Update File + Move to)
# from the main session pends, confirmed by the `M <destination>` line.
R="$TEST_ROOT/c1mv"; new_repo "$R"; printf '# x\n' > "$R/docs/specs/x.md"
cpost "$R" "$(patch_of $'*** Update File: docs/plans/x.md\n*** Move to: docs/specs/x.md\n@@\n-# x\n+# x')" "$(resp_of "M docs/specs/x.md")"
expect "S2: Update docs/plans/x.md + Move to docs/specs/x.md" context
check "  x pending" test -f "$R/.fablepowers/x/pending"
check "  context names the design and \$fablepowers:approve" bash -c '[[ "$1" == *docs/specs/x.md* && "$1" == *'\''$fablepowers:approve'\''* ]]' _ "$(text_of)"
printf '# y\n' > "$R/docs/specs/y.md"
cpost "$R" "$(patch_of $'*** Update File: docs/plans/y.md\n*** Move to: docs/specs/y.md\n@@\n-# y\n+# y')" "Exit code: 1"
check "S2: Move without an 'M <dest>' line (failed): no pending" test ! -e "$R/.fablepowers/y"
cpost "$R" "$(patch_of $'*** Update File: docs/plans/y.md\n*** Move to: docs/specs/y.md\n@@\n-# y\n+# y')" "$(resp_of "M docs/specs/y.md")" "$R" codex-post-apply_patch-subagent
check "S2: Move into docs/specs from a subagent: no pending" test ! -e "$R/.fablepowers/y"
cpost "$R" "$(patch_of $'*** Update File: docs/specs/y.md\n*** Move to: docs/plans/y.md\n@@\n-# y\n+# y')" "$(resp_of "M docs/plans/y.md")"
check "S2: Move out of docs/specs (source is the spec): no pending" test ! -e "$R/.fablepowers/y"
mkdir -p "$R/sub"
cpost "$R" "$(patch_of $'*** Update File: ../docs/plans/y.md\n*** Move to: ../docs/specs/y.md\n@@\n-# y\n+# y')" "$(resp_of "M ../docs/specs/y.md")" "$R/sub"
check "S2: Move into ../docs/specs from a subdirectory cwd pends" test -f "$R/.fablepowers/y/pending"

echo "13. Codex: apply_patch marker writes denied always"

R="$TEST_ROOT/c2"; new_repo "$R"
check "no pending: code patch allowed" test "$(cpatch "$R" "$(patch_of $'*** Add File: src/x.py\n+x')")" == allow
for op in "*** Add File: .fablepowers/k/approved" "*** Delete File: .fablepowers/k/pending" \
          "   *** Add File: .fablepowers/k/approved" $'\t*** Add File: .fablepowers/k/approved' \
          "*** Add File: .FablePowers/k/Approved." "*** Add File: .fablepowers/k/approved:s" \
          "*** Add File: /elsewhere/.fablepowers/k/approved"; do
  check "no pending: '$op' denied" test "$(cpatch "$R" "$(patch_of "*** Add File: docs/plans/ok.md"$'\n+ok\n'"$op"$'\n+x')")" == deny
done
check "no pending: Update docs/plans/a.md + Move to .fablepowers/k/approved denied" \
  test "$(cpatch "$R" "$(patch_of $'*** Update File: docs/plans/a.md\n*** Move to: .fablepowers/k/approved\n@@\n-a\n+a')")" == deny
check "no pending: Update .fablepowers/k/approved + Move to docs/plans/a.md denied" \
  test "$(cpatch "$R" "$(patch_of $'*** Update File: .fablepowers/k/approved\n*** Move to: docs/plans/a.md\n@@\n-a\n+a')")" == deny
cpatch "$R" "$(patch_of $'*** Add File: .fablepowers/k/approved\n+x')" >/dev/null
check "marker deny reason names \$fablepowers:approve" bash -c '[[ "$1" == *'\''`$fablepowers:approve`'\''* && "$1" == *"Do not retry"* ]]' _ "$(text_of)"
check "no pending: .fablepowers/k/approved.md allowed" test "$(cpatch "$R" "$(patch_of $'*** Add File: .fablepowers/k/approved.md\n+x')")" == allow
check "no pending: '+*** Add File: .fablepowers/k/approved' content line allowed" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: docs/plans/x.md\n+*** Add File: .fablepowers/k/approved')")" == allow
mkdir -p "$R/docs/plans/elsewhere" "$R/.fablepowers"; ln -s ../docs/plans/elsewhere "$R/.fablepowers/lk"
check "no pending: Add .fablepowers/<symlinked key>/approved denied (lexical path)" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: .fablepowers/lk/approved\n+x')")" == deny

echo "14. Codex: apply_patch while pending"

R="$TEST_ROOT/c3"; new_repo "$R"; mkdir -p "$R/src/deep"
ccreate "$R" docs/specs/feat.md
for op in $'*** Add File: src/x.py\n+x' $'*** Update File: src/app.py\n@@\n-hello\n+bye' "*** Delete File: src/app.py" \
          $'*** Add File: README.md\n+r' $'*** Add File: docs/specsX/a.md\n+a' $'*** Add File: docs/specs/../../src/y.py\n+y' \
          $'*** Update File: docs/plans/a.md\n*** Move to: src/b.py\n@@\n-a\n+a' \
          $'*** Update File: src/app.py\n*** Move to: docs/plans/app.py\n@@\n-a\n+a'; do
  check "pending: '${op%%$'\n'*}' denied" test "$(cpatch "$R" "$(patch_of "$op")")" == deny
done
cpatch "$R" "$(patch_of $'*** Add File: src/x.py\n+x')" >/dev/null
check "deny reason names the spec, \$fablepowers:approve feat and withdraw, no Claude command" \
  bash -c '[[ "$1" == *docs/specs/feat.md* && "$1" == *'\''$fablepowers:approve feat'\''* && "$1" == *'\''$fablepowers:withdraw feat'\''* && "$1" == *"Do not retry"* && "$1" != *"/fablepowers:approve"* && "$1" != *"answer Approve"* ]]' _ "$(text_of)"
check "deny reason says how to send it (text or \$ menu; app: text)" \
  bash -c '[[ "$1" == *'\''pick it from the `$` menu in the CLI'\''* && "$1" == *"in the Codex app, type it as text"* ]]' _ "$(text_of)"
for op in $'*** Add File: docs/plans/p.md\n+p' $'*** Update File: docs/specs/feat.md\n@@\n-# spec\n+# spec 2' \
          $'*** Add File: .fablepowers/feat/progress.md\n+p' $'*** Delete File: docs/plans/old.md'; do
  check "pending: '${op%%$'\n'*}' allowed" test "$(cpatch "$R" "$(patch_of "$op")")" == allow
done
check "pending: absolute path outside the repo allowed" test "$(cpatch "$R" "$(patch_of "*** Add File: $TEST_ROOT/elsewhere/x.py"$'\n+x')")" == allow
check "pending: allowed + disallowed in one patch denied" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: docs/plans/ok.md\n+ok\n*** Add File: src/evil.py\n+e')")" == deny
cpatch "$R" "$(patch_of $'*** Add File: docs/plans/ok.md\n+ok\n*** Add File: src/evil.py\n+e')" >/dev/null
check "  the reason names only the disallowed path" bash -c '[[ "$1" == *"\`src/evil.py\`"* && "$1" != *"\`docs/plans/ok.md\`"* ]]' _ "$(text_of)"
# M1: Codex trims patch lines, so indented headers, CRLF and trailing spaces apply.
check "pending: second op indented with spaces, disallowed: denied" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: docs/plans/ok.md\n+ok\n   *** Add File: src/evil.py\n+e')")" == deny
check "pending: second op indented with a tab, disallowed: denied" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: docs/plans/ok.md\n+ok\n\t*** Update File: src/app.py\n@@\n-hello\n+bye')")" == deny
check "pending: CRLF patch with a disallowed path denied" \
  test "$(cpatch "$R" $'*** Begin Patch\r\n*** Add File: docs/plans/ok.md\r\n+ok\r\n*** Add File: src/evil.py\r\n+e\r\n*** End Patch\r\n')" == deny
check "pending: CRLF patch inside the allowlist allowed" \
  test "$(cpatch "$R" $'*** Begin Patch\r\n*** Add File: docs/plans/crlf.md\r\n+ok\r\n*** End Patch\r\n')" == allow
check "pending: path with trailing spaces (src/evil.py   ) denied" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: src/evil.py   \n+e')")" == deny
check "pending: indented '  *** Begin Patch' with a disallowed path denied" \
  test "$(cpatch "$R" $'  *** Begin Patch\n  *** Add File: src/evil.py\n+e\n  *** End Patch')" == deny
# Review focus 1: paths are relative to the payload cwd.
check "pending, cwd src/deep: docs/specs/z.md (= src/deep/docs/specs) denied" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: docs/specs/z.md\n+z')" "$R/src/deep")" == deny
check "pending, cwd src/deep: ../../docs/plans/q.md allowed" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: ../../docs/plans/q.md\n+q')" "$R/src/deep")" == allow
ln -s ../../src "$R/docs/plans/srclink"
check "pending: patch through a symlink from docs/plans to src denied" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: docs/plans/srclink/z.py\n+z')")" == deny
# The Edit matcher (Codex fires both Write and Edit for apply_patch) gives the same answer.
cpatch "$R" "$(patch_of $'*** Add File: src/x.py\n+x')" >/dev/null; w="$OUT"
cpatch "$R" "$(patch_of $'*** Add File: src/x.py\n+x')" "$R" Edit >/dev/null
check "duplicate invocation (Write and Edit matchers): identical deny" test "$OUT" == "$w"
# Unparseable patches fail closed while pending (S4).
check "pending: patch with no file operation denied" test "$(cpatch "$R" $'*** Begin Patch\n*** End Patch')" == deny
cpatch "$R" $'*** Begin Patch\n*** End Patch' >/dev/null
check "  the reason says the patch could not be parsed" bash -c '[[ "$1" == *"could not parse"* ]]' _ "$(text_of)"
check "pending: header with an empty path denied" test "$(cpatch "$R" "$(patch_of $'*** Add File:   \n+x')")" == deny
check "pending: header with an empty path, cwd docs/plans, denied (not read as the cwd)" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: docs/plans/ok.md\n+ok\n*** Delete File:')" "$R/docs/plans")" == deny
check "pending: tool_input with no patch text denied" test "$(cpatch "$R" "echo hi")" == deny
run_gate_json PreToolUse Write "$(payload codex-pre-apply_patch CWD="$R" PATCH=x | python3 -c '
import json,sys; d = json.load(sys.stdin); d["tool_input"] = {"input": sys.argv[1]}; print(json.dumps(d))' "$(patch_of $'*** Add File: src/evil.py\n+e')")"
note_deny
expect "pending: patch in another tool_input field (input), disallowed path" deny
run_gate_json PreToolUse Write "$(payload codex-pre-apply_patch CWD="$R" PATCH=x | python3 -c '
import json,sys; d = json.load(sys.stdin); d["tool_input"] = {"input": sys.argv[1]}; print(json.dumps(d))' "$(patch_of $'*** Add File: docs/plans/in.md\n+i')")"
expect "pending: patch in another tool_input field (input), allowed path" allow
run_gate PreToolUse Write codex-v1-pre-apply_patch CWD="$R" PATCH="$(patch_of $'*** Add File: src/v1.py\n+x')"
note_deny
expect "pending: v1 apply_patch code path" deny
GATE_ENV=(FABLEPOWERS_GATE=off)
check "off: pending code patch allowed" test "$(cpatch "$R" "$(patch_of $'*** Add File: src/x.py\n+x')")" == allow
check "off: logged" grep -q 'would deny apply_patch' "$R/.fablepowers/gate.log"
GATE_ENV=()
R="$TEST_ROOT/c3n"; new_repo "$R"
check "no pending: patch with no file operation allowed" test "$(cpatch "$R" $'*** Begin Patch\n*** End Patch')" == allow
check "  logged" grep -q 'Codex apply_patch without a parseable patch' "$R/.fablepowers/gate.log"

echo "14b. Codex: header paths with control characters or that cannot be resolved"

# cpatch_esc <repo> <patch> [cwd]: as cpatch, with @NUL@, @SOH@, @DEL@ and @SUR@ in
# the patch sent as the JSON escapes \u0000, \u0001, \u007f and \ud800 (a lone
# surrogate: no control character, but resolving it raises). Bash strings cannot
# carry NUL, so the escapes are put into the JSON text.
cpatch_esc() {
  local input
  input="$(payload codex-pre-apply_patch CWD="${3:-$1}" PATCH="$2")"
  input="${input//@NUL@/\\u0000}"; input="${input//@SOH@/\\u0001}"
  input="${input//@DEL@/\\u007f}"; input="${input//@SUR@/\\ud800}"
  input="$(printf '%s' "$input" | sed -E 's/@u([0-9a-f]{4})@/\\u\1/g')"   # @uXXXX@ -> \uXXXX
  run_gate_json PreToolUse Write "$input"; note_deny; verdict
}
R="$TEST_ROOT/c3c"; new_repo "$R"
# Before the fix, a NUL in any header path made resolution raise and the whole
# patch fell through to the outer "internal error, allowed" (fail open).
check "no pending: NUL path does not mask a marker in the same patch (denied)" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: docs/plans/n@NUL@.md\n+n\n*** Add File: .fablepowers/k/approved\n+x')")" == deny
check "no pending: unresolvable (surrogate) path does not mask a marker (denied)" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: docs/plans/n@SUR@.md\n+n\n*** Add File: .fablepowers/k/approved\n+x')")" == deny
for p in ".fablepowers/k/approved@NUL@" ".fablepowers/k/pend@SOH@ing" ".FablePowers/k/Approved@DEL@" ".fablepowers/k/approved@SUR@"; do
  check "no pending: marker-like path '$p' denied" test "$(cpatch_esc "$R" "$(patch_of "*** Add File: $p"$'\n+x')")" == deny
done
check "no pending: control-character path not marker-like allowed" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: src/a@NUL@.py\n+x')")" == allow
check "no pending: control-character path under .fablepowers, no marker name, allowed" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: .fablepowers/k/report@NUL@.md\n+x')")" == allow
check "  logged as a path the gate cannot check" grep -q 'cannot check' "$R/.fablepowers/gate.log"
check "  no internal error logged" bash -c '! grep -q "internal error" "$1"' _ "$R/.fablepowers/gate.log"
# A symlink whose name holds a control character, leading into .fablepowers/<key>/:
# the path has no `.fablepowers` in it, so only resolving it shows the marker.
mkdir -p "$R/.fablepowers/k"; ln -s ../../.fablepowers/k "$R/docs/plans/l"$'\x01'; ln -s ../../.fablepowers/k "$R/docs/plans/lk"
check "no pending: 'docs/plans/l<SOH>/approved' (symlink into .fablepowers/k) denied" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: docs/plans/l@SOH@/approved\n+x')")" == deny
check "no pending: 'docs/plans/l<SOH>k/pending' (control-stripped: symlink lk) denied" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: docs/plans/l@SOH@k/pending\n+x')")" == deny
check "no pending: 'docs/plans/l<SOH>/notes.md' (symlink, not a marker) allowed" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: docs/plans/l@SOH@/notes.md\n+x')")" == allow
rm "$R/docs/plans/l"$'\x01' "$R/docs/plans/lk"; rmdir "$R/.fablepowers/k"
ccreate "$R" docs/specs/ctl.md
check "pending: allowed + NUL path + disallowed path denied" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: docs/plans/ok.md\n+ok\n*** Add File: docs/plans/n@NUL@.md\n+n\n*** Add File: src/evil.py\n+e')")" == deny
for p in "docs/plans/a@NUL@.md" "docs/plans/a@SOH@.md" "docs/plans/a@DEL@.md" "docs/plans/a@SUR@.md"; do
  check "pending: '$p' alone denied (fails closed)" test "$(cpatch_esc "$R" "$(patch_of "*** Add File: $p"$'\n+x')")" == deny
done
check "pending: tab inside a path (docs/plans/a<TAB>b.md) denied" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: docs/plans/a\tb.md\n+x')")" == deny
# M1: Codex splits patch lines on "\n" only. Before the fix the gate split with
# str.splitlines, so each of these characters cut the header path short at
# `docs/specs/a.md` (allowed) while Codex wrote src/evil.py.
for c in 000b 000c 001c 001d 001e 0085 2028 2029 000d; do
  check "pending: 'docs/specs/a.md<U+$c>/../../../src/evil.py' denied" \
    test "$(cpatch_esc "$R" "$(patch_of "*** Add File: docs/specs/a.md@u$c@/../../../src/evil.py"$'\n+x')")" == deny
  check "pending: 'Move to: docs/specs/a.md<U+$c>/../../../src/evil.py' denied" \
    test "$(cpatch_esc "$R" "$(patch_of "*** Update File: docs/plans/a.md"$'\n'"*** Move to: docs/specs/a.md@u$c@/../../../src/evil.py"$'\n@@\n-a\n+a')")" == deny
  check "pending: 'docs/plans/a<U+$c>.md' (inside the allowlist) denied: the control check fails closed" \
    test "$(cpatch_esc "$R" "$(patch_of "*** Add File: docs/plans/a@u$c@.md"$'\n+x')")" == deny
done
cpatch_esc "$R" "$(patch_of $'*** Add File: docs/specs/a.md@u2028@/../../../src/evil.py\n+x')" >/dev/null
check "  the reason shows the separator escaped and says the gate fails closed" \
  bash -c '[[ "$1" == *'\''docs/specs/a.md\u2028/'\''* && "$1" == *"fails closed"* ]]' _ "$(text_of)"
# The header path is taken as Codex takes it: untrimmed after ": ", so extra
# leading blanks or a leading \x1c name a different file (outside the allowlist).
check "pending: 'Add File:   docs/plans/s.md' (Codex writes '  docs/plans/s.md') denied" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File:   docs/plans/s.md\n+x')")" == deny
check "pending: 'Add File: <U+001c>docs/plans/x.md' denied" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: @u001c@docs/plans/x.md\n+x')")" == deny
check "pending: 'Add File: docs/plans<U+001c>' (trailing, kept by Codex) denied" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: docs/plans@u001c@\n+x')")" == deny
check "pending: 'Add File: docs/plans/ok.md' + trailing U+3000 (trimmed by Codex) allowed" \
  test "$(cpatch_esc "$R" "$(patch_of $'*** Add File: docs/plans/ok.md@u3000@\n+x')")" == allow
check "pending: header indented with U+3000 (Codex trims it) still checked: src/x.py denied" \
  test "$(cpatch_esc "$R" "$(patch_of $'@u3000@*** Add File: src/x.py\n+x')")" == deny
cpatch_esc "$R" "$(patch_of $'*** Add File: docs/plans/a@NUL@.md\n+x')" >/dev/null
check "  the reason shows the path escaped and says the gate fails closed" \
  bash -c '[[ "$1" == *'\''docs/plans/a\x00.md'\''* && "$1" == *"fails closed"* && "$1" == *'\''$fablepowers:approve ctl'\''* ]]' _ "$(text_of)"
check "pending: non-ASCII path inside the allowlist (docs/plans/é.md) still allowed" \
  test "$(cpatch "$R" "$(patch_of $'*** Add File: docs/plans/\xc3\xa9.md\n+x')")" == allow

echo "15. Codex: config files while pending"

R="$TEST_ROOT/c4"; new_repo "$R"
H="$TEST_ROOT/chome"; mkdir -p "$H/.codex"
check "no pending: ~/.codex/config.toml allowed" test "$(cpatch "$R" "$(patch_of "*** Update File: $H/.codex/config.toml"$'\n@@\n-a\n+b')")" == allow
check "no pending: <repo>/.codex/rules/x.rules allowed" test "$(cpatch "$R" "$(patch_of $'*** Add File: .codex/rules/x.rules\n+x')")" == allow
ccreate "$R" docs/specs/cfg.md
# Outside the repo (under $H) only the config guard denies; inside, the allowlist would too.
for f in "$H/.codex/config.toml" "$R/.codex/config.toml" .codex/config.toml .codex/rules/fablepowers.rules "$H/.codex/rules/x.rules" \
         .codex/agents/x.toml "$H/.codex/agents/x.toml" .codex/hooks.json "$H/.codex/hooks.json" "$H/.codex/hooks/x.sh" \
         docs/plans/.codex/config.toml docs/plans/.codex/rules/x.rules \
         "$H/.Codex/Config.TOML" "$H/.codex/config.toml." "$H/.codex./rules/x" "$H/.CODEX/Agents/x"; do
  check "pending: patch '$f' denied" test "$(cpatch "$R" "$(patch_of "*** Add File: $f"$'\n+x')")" == deny
done
cpatch "$R" "$(patch_of "*** Update File: $H/.codex/config.toml"$'\n@@\n-a\n+b')" >/dev/null
check "config deny names the file, the design and \$fablepowers:approve" \
  bash -c '[[ "$1" == *"Codex config file"* && "$1" == *.codex/config.toml* && "$1" == *docs/specs/cfg.md* && "$1" == *'\''$fablepowers:approve cfg'\''* ]]' _ "$(text_of)"
ln -s "$H/.codex" "$TEST_ROOT/codexlink"
check "pending: config.toml through a symlink to ~/.codex denied" test "$(cpatch "$R" "$(patch_of "*** Update File: $TEST_ROOT/codexlink/config.toml"$'\n@@\n-a\n+b')")" == deny
CH="$TEST_ROOT/codex-home-elsewhere"; mkdir -p "$CH"
check "pending, CODEX_HOME unset: <dir>/config.toml outside the repo allowed" test "$(cpatch "$R" "$(patch_of "*** Add File: $CH/config.toml"$'\n+x')")" == allow
GATE_ENV=("CODEX_HOME=$CH")
check "pending: \$CODEX_HOME/config.toml denied" test "$(cpatch "$R" "$(patch_of "*** Add File: $CH/config.toml"$'\n+x')")" == deny
GATE_ENV=()
for f in "$H/.codex/sessions/x.jsonl" "$H/.codex/config.toml.bak" "$H/codex/config.toml" "$H/.codex/notes/rules"; do
  check "pending: '$f' (not Codex config, outside the repo) allowed" test "$(cpatch "$R" "$(patch_of "*** Add File: $f"$'\n+x')")" == allow
done

echo "16. Codex: spawns while pending"

R="$TEST_ROOT/c5"; new_repo "$R"
check "no pending: v2 implementer spawn allowed" test "$(cspawn2 "$R" fablepowers_implementer_t1)" == allow
check "no pending: v1 implementer spawn allowed" test "$(cspawn1 "$R" $'fablepowers-seat: implementer\nGo.')" == allow
ccreate "$R" docs/specs/sp.md
for t in fablepowers_reviewer_t1 fablepowers_reviewer fablepowers_reviewer_t3_r2; do
  check "pending: v2 task_name $t allowed" test "$(cspawn2 "$R" "$t")" == allow
done
for t in fablepowers_implementer_t1 fablepowers_strict_implementer_t1 fablepowers_reviewerx "" worker fablepowers-reviewer-t0 x_fablepowers_reviewer_t1; do
  check "pending: v2 task_name '$t' denied" test "$(cspawn2 "$R" "$t")" == deny
done
run_gate_json PreToolUse collaborationspawn_agent "$(payload codex-v2-pre-spawn CWD="$R" TASK=x | python3 -c '
import json,sys; d = json.load(sys.stdin); del d["tool_input"]["task_name"]; print(json.dumps(d))')"
note_deny
expect "pending: v2 spawn without task_name" deny
cspawn2 "$R" fablepowers_implementer_t1 >/dev/null
check "v2 deny names the agent, the design and \$fablepowers:approve sp" \
  bash -c '[[ "$1" == *fablepowers_implementer_t1* && "$1" == *docs/specs/sp.md* && "$1" == *'\''$fablepowers:approve sp'\''* ]]' _ "$(text_of)"
check "pending: v1 reviewer seat line allowed" test "$(cspawn1 "$R" $'fablepowers-seat: reviewer\nRead agents/reviewer.md.')" == allow
check "pending: v1 reviewer seat line with CRLF allowed" test "$(cspawn1 "$R" $'fablepowers-seat: reviewer\r\nGo.')" == allow
for m in $'fablepowers-seat: implementer\nRead agents/implementer.md.' \
         $'fablepowers-seat: implementer\nAlso see agents/reviewer.md and fablepowers-seat: reviewer.' \
         $'Hello\nfablepowers-seat: reviewer' "Read agents/reviewer.md as your role prompt." "" \
         $'fablepowers-seat: reviewers\nGo.'; do
  check "pending: v1 message '${m%%$'\n'*}...' denied" test "$(cspawn1 "$R" "$m")" == deny
done
check "pending: v1 implementer spawn via the Agent matcher denied too" test "$(cspawn1 "$R" $'fablepowers-seat: implementer\nGo.' Agent)" == deny
check "pending: Claude Agent dispatch unaffected (implementer denied, Claude wording)" test "$(agent_verdict "$R" fablepowers:implementer)" == deny
agent_verdict "$R" fablepowers:implementer >/dev/null
check "  Claude wording kept" bash -c '[[ "$1" == *"/fablepowers:approve sp"* && "$1" != *'\''$fablepowers'\''* ]]' _ "$(text_of)"

echo "17. Codex: \$fablepowers:approve / withdraw"

R="$TEST_ROOT/c6"; new_repo "$R"
cups "$R" '$fablepowers:approve'
expect "nothing pending" context
check "  says so" bash -c '[[ "$1" == *"nothing is pending"* ]]' _ "$(text_of)"
check "  no marker" test ! -e "$R/.fablepowers"
ccreate "$R" docs/specs/one.md
for p in '$fablepowers:approve a b' 'please $fablepowers:approve' $'$fablepowers:approve\nyes' \
         $'$fablepowers:approve\n\n' $'$fablepowers:approve\r\n\r\n' $'$fablepowers:approve\n ' $'\n$fablepowers:approve' \
         $'$fablepowers:approve\r' '$fablepowers:approvex' '/fablepowers:approve' '$fablepowers:Approve' 'fablepowers:approve' \
         '$fablepowers:approve one two' ''; do
  cups "$R" "$p"
  q="${p//$'\r'/\\r}"
  check "not an approval: '${q//$'\n'/\\n}' (allowed, nothing recorded)" test "$(verdict)" == allow -a ! -e "$R/.fablepowers/one/approved"
done
# One trailing word is the key argument: one that names no pending design records nothing.
for p in '$fablepowers:approve please' '$fablepowers:approve one.'; do
  cups "$R" "$p"
  check "not an approval: '$p' (no such key: context, nothing recorded)" \
    bash -c '[[ "$1" == context && "$2" == *"no pending design matches"* ]]' _ "$(verdict)" "$(text_of)"
  check "  nothing recorded" test ! -e "$R/.fablepowers/one/approved"
done
cups "$R" '$fablepowers:approve' codex-ups-child
check "with agent_id (a subagent prompt): nothing recorded" test "$(verdict)" == allow -a ! -e "$R/.fablepowers/one/approved"
cups "$R" '$fablepowers:approve' ups-claude
check "Claude Code UserPromptSubmit (no turn_id): nothing recorded" test "$(verdict)" == allow -a ! -e "$R/.fablepowers/one/approved"
cups "$R" $' \t$fablepowers:approve \t'
expect "one pending, blanks around the command" context
A="$R/.fablepowers/one/approved"
check "  approved written, via command" test "$(json_field "$A" via)" == '"command"'
check "  approved.spec_sha256 matches the spec" test "$(json_field "$A" spec_sha256)" == "\"$(sha256sum "$R/docs/specs/one.md" | cut -d' ' -f1)\""
check "  context says it is recorded" bash -c '[[ "$1" == *"approved design \`docs/specs/one.md\`"* ]]' _ "$(text_of)"
cp "$A" "$TEST_ROOT/c6-approved"
cups "$R" '$fablepowers:approve'
expect "duplicate approve (idempotent)" context
check "  approved unchanged" cmp -s "$A" "$TEST_ROOT/c6-approved"
check "approved: v2 implementer spawn allowed" test "$(cspawn2 "$R" fablepowers_implementer_t1)" == allow
check "approved: v1 implementer spawn allowed" test "$(cspawn1 "$R" $'fablepowers-seat: implementer\nGo.')" == allow
check "approved: code patch allowed" test "$(cpatch "$R" "$(patch_of $'*** Add File: src/x.py\n+x')")" == allow

# N2: one trailing newline (LF or CRLF) after the command still approves.
for nl in LF CRLF; do
  R="$TEST_ROOT/c6nl-$nl"; new_repo "$R"
  ccreate "$R" docs/specs/nl.md
  if [[ "$nl" == LF ]]; then cups "$R" $'$fablepowers:approve nl\n'; else cups "$R" $'$fablepowers:approve nl\r\n'; fi
  check "one trailing $nl after the command: approved" \
    bash -c '[[ "$1" == context && -f "$2" ]]' _ "$(verdict)" "$R/.fablepowers/nl/approved"
done

R="$TEST_ROOT/c6b"; new_repo "$R"
ccreate "$R" docs/specs/a.md
ccreate "$R" docs/specs/b.md
cups "$R" '$fablepowers:approve'
expect "several pending, no key: context, not a block" context
check "  lists both keys and the command" bash -c '[[ "$1" == *"a (docs/specs/a.md)"* && "$1" == *"b (docs/specs/b.md)"* && "$1" == *'\''$fablepowers:approve <key>'\''* ]]' _ "$(text_of)"
check "  nothing recorded" test ! -e "$R/.fablepowers/a/approved" -a ! -e "$R/.fablepowers/b/approved"
cups "$R" '$fablepowers:approve zzz'
expect "several pending, unknown key" context
check "  nothing recorded" test ! -e "$R/.fablepowers/a/approved" -a ! -e "$R/.fablepowers/b/approved"
cups "$R" '$fablepowers:approve docs/specs/b.md'
expect "several pending, spec path b" context
check "  only b approved" test -f "$R/.fablepowers/b/approved" -a ! -e "$R/.fablepowers/a/approved"
check "one still pending: v2 implementer spawn denied" test "$(cspawn2 "$R" fablepowers_implementer_t1)" == deny
cups "$R" '$fablepowers:withdraw'
expect "withdraw, one pending (a)" context
check "  a/pending removed, spec kept" test ! -e "$R/.fablepowers/a/pending" -a -f "$R/docs/specs/a.md"
check "after withdraw: v2 implementer spawn allowed" test "$(cspawn2 "$R" fablepowers_implementer_t1)" == allow
R="$TEST_ROOT/c6c"; new_repo "$R"
ccreate "$R" docs/specs/a.md
ccreate "$R" docs/specs/b.md
cups "$R" '$fablepowers:withdraw'
expect "withdraw, several pending, no key" context
check "  both still pending" test -f "$R/.fablepowers/a/pending" -a -f "$R/.fablepowers/b/pending"
cups "$R" '$fablepowers:withdraw a'
check "withdraw a: only a removed" test ! -e "$R/.fablepowers/a/pending" -a -f "$R/.fablepowers/b/pending"
GATE_ENV=("FABLEPOWERS_PYTHON=$(command -v python3)")
cups "$R" '$fablepowers:approve b'
expect "UserPromptSubmit through the launcher's payload hand-off to python" context
check "  b approved" test -f "$R/.fablepowers/b/approved"
GATE_ENV=()
PAYLOAD_COMPACT=1
R="$TEST_ROOT/c6d"; new_repo "$R"
ccreate "$R" docs/specs/cx.md
expect "compact JSON: Codex spec add" context
check "compact JSON: v2 implementer spawn denied" test "$(cspawn2 "$R" fablepowers_implementer_t1)" == deny
cups "$R" '$fablepowers:approve'
expect "compact JSON: \$fablepowers:approve" context
check "compact JSON: approved" test -f "$R/.fablepowers/cx/approved"
PAYLOAD_COMPACT=0

echo "18. Codex: launcher fast path and no-python warnings"

# UserPromptSubmit without `$fablepowers:` exits before python is looked for.
printf '#!/bin/sh\ntouch "%s/py-ran"\nexec python3 "$@"\n' "$TEST_ROOT" > "$TEST_ROOT/tracepy"; chmod +x "$TEST_ROOT/tracepy"
R="$TEST_ROOT/c7"; new_repo "$R"; mkdir -p "$R/.fablepowers"
GATE_ENV=("FABLEPOWERS_PYTHON=$TEST_ROOT/tracepy")
rm -f "$TEST_ROOT/py-ran"
cups "$R" 'Reply with the single word OK.'
check "UserPromptSubmit without \$fablepowers: allowed" test "$(verdict)" == allow
check "  python never started" test ! -e "$TEST_ROOT/py-ran"
cups "$R" 'Reply OK.' ups-claude
check "Claude Code prompt: python never started" test ! -e "$TEST_ROOT/py-ran"
cups "$R" '$fablepowers:approve'
check "UserPromptSubmit with \$fablepowers: starts python" test -e "$TEST_ROOT/py-ran"
GATE_ENV=()

CWARNED="$GATE_TMP/fablepowers-gate-warned-$UID-01a1408b-1e59-7092-843b-bc23a311d75f"
# S1: on Codex Post apply_patch and UserPromptSubmit the warning also goes out as
# additionalContext, since Codex shows a systemMessage to neither the model nor
# an exec user.
cwarning() {  # cwarning <hookEventName>: the exact no-python output for that Codex event
  printf '{"systemMessage":"fablepowers approval gate disabled: python3 not found","hookSpecificOutput":{"hookEventName":"%s","additionalContext":"fablepowers approval gate disabled: python3 not found. The design-approval gate is not running in this session: no design is marked pending and `$fablepowers:approve` records nothing. Tell the user this now, so they can install Python 3.8+ (or set FABLEPOWERS_PYTHON) and restart the session."}}' "$1"
}
# codex_warned <event>: $OUT is that output, valid JSON, its context names the gate.
codex_warned() {
  [[ "$RC" == 0 && "$OUT" == "$(cwarning "$1")" ]] && printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin); h = d["hookSpecificOutput"]
assert h["hookEventName"] == sys.argv[1] and "gate disabled" in h["additionalContext"]' "$1"
}
cnopy() {  # cnopy <label> <repo>: no-python checks for Codex payloads (repo without .fablepowers/)
  local L="$1" R="$2"
  reset_warned
  cups "$R" 'Reply OK.'
  expect "no python, $L: prompt without \$fablepowers: silent" allow
  cups "$R" '$fablepowers:approve' ups-claude
  expect "no python, $L: Claude prompt '\$fablepowers:approve' (no turn_id) silent" allow
  cpost "$R" "$(patch_of $'*** Add File: src/new.py\n+x')" "$(resp_of "A src/new.py")"
  expect "no python, $L: non-spec Add silent" allow
  cpost "$R" "$(patch_of $'*** Add File: docs/specs/n.txt\n+x\n*** Add File: src/docs/specsx/a.md\n+x')" "$(resp_of)"
  expect "no python, $L: non-.md / docs/specs-like Adds silent" allow
  cpost "$R" "$(patch_of $'*** Update File: docs/specs/a.md\n@@\n-a\n+b')" "$(resp_of "M docs/specs/a.md")"
  expect "no python, $L: spec Update silent" allow
  run_gate PreToolUse Write codex-pre-apply_patch CWD="$R" PATCH="$(patch_of $'*** Add File: docs/specs/a.md\n+x')"
  expect "no python, $L: PreToolUse spec Add silent" allow
  run_gate PreToolUse collaborationspawn_agent codex-v2-pre-spawn CWD="$R" TASK=fablepowers_implementer_t1
  expect "no python, $L: spawn silent" allow
  check "  $L: no warn-once marker yet" test ! -e "$CWARNED"
  cpost "$R" "$(patch_of $'*** Add File: src/x.py\n+x\n  *** Add File: docs/specs/a.md   \n+x')" "$(resp_of)"
  check "no python, $L: Post apply_patch adding a spec (second, indented op) warns with PostToolUse context" codex_warned PostToolUse
  check "  $L: warn-once marker" test -f "$CWARNED"
  cpost "$R" "$(patch_of $'*** Add File: docs/specs/b.md\n+x')" "$(resp_of "A docs/specs/b.md")"
  expect "no python, $L: second spec Add in the session silent" allow
  reset_warned
  cups "$R" '$fablepowers:approve'
  check "no python, $L: \$fablepowers:approve warns with UserPromptSubmit context" codex_warned UserPromptSubmit
  cups "$R" '$fablepowers:withdraw'
  expect "no python, $L: \$fablepowers:withdraw once per session" allow
  reset_warned
  cups "$R" 'run $fablepowers:withdraw please'
  check "no python, $L: prompt holding \$fablepowers: warns with UserPromptSubmit context" codex_warned UserPromptSubmit
  reset_warned
  cpost "$R" "$(patch_of $'*** Update File: docs/plans/m.md\n*** Move to: docs/specs/m.md\n@@\n-a\n+a')" "$(resp_of "M docs/specs/m.md")"
  check "no python, $L: Post apply_patch moving a file into docs/specs warns with PostToolUse context" codex_warned PostToolUse
  reset_warned
  cpost "$R" "$(patch_of $'*** Update File: docs/specs/m.md\n*** Move to: docs/plans/m.md\n@@\n-a\n+a')" "$(resp_of "M docs/plans/m.md")"
  expect "no python, $L: moving a spec out of docs/specs silent" allow
  check "  $L: no .fablepowers/ created" test ! -e "$R/.fablepowers"
}
GATE_ENV=("FABLEPOWERS_PYTHON=/nonexistent")
RQ="$TEST_ROOT/c8"; new_repo "$RQ"
cnopy "fresh repo" "$RQ"
PAYLOAD_COMPACT=1
RQ="$TEST_ROOT/c8c"; new_repo "$RQ"
cnopy "compact JSON, fresh repo" "$RQ"
PAYLOAD_COMPACT=0
reset_warned
RQ="$TEST_ROOT/c8f"; new_repo "$RQ"; mkdir -p "$RQ/.fablepowers"
cups "$RQ" 'Reply OK.'
expect "no python, repo with .fablepowers/: prompt without \$fablepowers: silent (fast path)" allow
run_gate PreToolUse collaborationspawn_agent codex-v2-pre-spawn CWD="$RQ" TASK=fablepowers_implementer_t1
expect "no python, repo with .fablepowers/: spawn warns" warning
check "  PreToolUse: systemMessage only" test "$OUT" == "$WARNING"
reset_warned
cpost "$RQ" "$(patch_of $'*** Add File: src/x.py\n+x')" "$(resp_of "A src/x.py")"
check "no python, repo with .fablepowers/: any Codex Post apply_patch warns with PostToolUse context" codex_warned PostToolUse
GATE_ENV=()
reset_warned

echo "19. Codex deny messages carry the recovery line"

n="$(grep -c . "$CODEX_DENIES" || true)"
check "Codex deny messages collected ($n)" test "$n" -ge 40
check "every Codex deny message has the /hooks trust + FABLEPOWERS_GATE=off recovery line" \
  bash -c '! grep -v -F "trust them in \`/hooks\`, or set \`FABLEPOWERS_GATE=off\`" "$1" | grep -q .' _ "$CODEX_DENIES"
# N1: Codex appends ". Tool: <name>" to a deny reason, so none may end with a period.
check "no Codex deny message ends with a period (no '..' once Codex appends '. Tool: …')" \
  bash -c '! grep -E "\.[[:space:]]*$" "$1" | grep -q .' _ "$CODEX_DENIES"
check "no Codex deny message points at the Claude Code command or question" \
  bash -c '! grep -E "/fablepowers:(approve|withdraw)|answer Approve" "$1" | grep -q .' _ "$CODEX_DENIES"

echo "20. scripts/codex-hook-trust.sh: nothing on stdout unless it succeeds"

# A stub `codex app-server` speaking just enough JSON-RPC: STUB_MODE=ok lists one
# fablepowers hook, other lists only another plugin's, die exits at once, garbage
# answers hooks/list with a non-JSON-RPC line and then exits.
STUB="$TEST_ROOT/stub-codex"; mkdir -p "$STUB"
cat > "$STUB/codex" <<'EOF2'
#!/usr/bin/env python3
import json, os, sys
mode = os.environ.get("STUB_MODE", "ok")
if mode == "die":
    sys.exit(3)
for line in sys.stdin:
    req = json.loads(line)
    if req.get("id") == 0:
        print(json.dumps({"id": 0, "result": {}}), flush=True)
    elif req.get("id") == 1:
        if mode == "garbage":
            print("not json", flush=True); sys.exit(0)
        pid = "fablepowers@fablepowers" if mode == "ok" else "other@x"
        print(json.dumps({"id": 1, "result": {"data": [{"hooks": [
            {"pluginId": pid, "key": pid + ":hooks/hooks.json:pre_tool_use:0:0", "currentHash": "abc"}]}]}}), flush=True)
EOF2
chmod +x "$STUB/codex"
trust_run() {  # trust_run <mode> [PATH]: stdout -> $TOUT, stderr -> $TERR, exit -> $TRC
  TRC=0
  TOUT="$(STUB_MODE="$1" PATH="${2:-$STUB:$PATH}" "$BASH" "$TRUST_SH" fablepowers@fablepowers "$TEST_ROOT" 2>"$TEST_ROOT/trust-err")" || TRC=$?
  TERR="$(cat "$TEST_ROOT/trust-err")"
}
trust_run ok
check "plugin listed: exit 0, one hooks.state override on stdout" \
  test "$TRC:$TOUT" == '0:hooks.state={"fablepowers@fablepowers:hooks/hooks.json:pre_tool_use:0:0"={trusted_hash="abc"}}'
for m in other die garbage; do
  trust_run "$m"
  check "stub mode $m: non-zero exit, empty stdout, a message on stderr" \
    bash -c '[[ "$1" != 0 && -z "$2" && "$3" == *codex-hook-trust* ]]' _ "$TRC" "$TOUT" "$TERR"
done
mkdir -p "$TEST_ROOT/py-only"; ln -sf "$(command -v python3)" "$TEST_ROOT/py-only/python3"
trust_run ok "$TEST_ROOT/py-only"
check "codex not on PATH: non-zero exit, empty stdout" bash -c '[[ "$1" != 0 && -z "$2" && "$3" == *"codex not found"* ]]' _ "$TRC" "$TOUT" "$TERR"
# The documented headless usage stops instead of running `codex -c ""`.
out="$(STUB_MODE=die PATH="$STUB:$PATH" bash -c 'trust="$(bash "$1" fablepowers@fablepowers)" || exit 1; echo "ran codex with: $trust"' _ "$TRUST_SH" 2>/dev/null)" && rc=0 || rc=$?
check "documented usage: helper error stops before codex runs" test "$rc:$out" == "1:"

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All approval-gate tests passed."
else
  echo "$FAILURES approval-gate test(s) failed."
  exit 1
fi
