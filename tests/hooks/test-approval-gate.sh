#!/usr/bin/env bash
# Tests for the design-approval gate: hooks/approval-gate (launcher),
# hooks/approval_gate.py, their hooks.json entries, and the user-only
# approve/withdraw skills.
#
# Every gate run goes through the literal "command" string hooks.json holds for
# that event and matcher, with CLAUDE_PLUGIN_ROOT set to a temp plugin tree, via
# "bash -c", with a payload built from tests/hooks/fixtures/gate/*.json (shaped
# on the payloads Claude Code 2.1.299 sent in the gate spike). Placeholders
# __CWD__, __FILE__, __SUBAGENT__, __COMMAND__, __ARGS__ and __ANSWER__ are
# replaced inside JSON strings. Repos are temp git repos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/gate"
# Overrides for the files under test (mutation checks on a copy).
HOOKS_JSON="${HOOKS_JSON:-$REPO_ROOT/hooks/hooks.json}"
GATE_LAUNCHER="${GATE_LAUNCHER:-$REPO_ROOT/hooks/approval-gate}"
GATE_PY="${GATE_PY:-$REPO_ROOT/hooks/approval_gate.py}"
SKILLS_DIR="${SKILLS_DIR:-$REPO_ROOT/skills}"
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
# with exactly that matcher; exit 1 if there is not exactly one such entry.
hook_cmd() {
  python3 - "$PLUGIN/hooks/hooks.json" "$1" "$2" <<'EOF'
import json, sys
entries = [e for e in json.load(open(sys.argv[1]))["hooks"].get(sys.argv[2], []) if e.get("matcher") == sys.argv[3]]
if len(entries) != 1 or len(entries[0]["hooks"]) != 1:
    sys.exit(1)
print(entries[0]["hooks"][0]["command"])
EOF
}

# payload <fixture> NAME=value...: the fixture with placeholders __NAME__ replaced.
payload() {
  python3 - "$FIXTURES/$1.json" "${@:2}" <<'EOF'
import json, sys
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
print(json.dumps(walk(json.load(open(sys.argv[1])))))
EOF
}

# run_gate <event> <matcher> <fixture> NAME=value...: run the hooks.json command
# for that event/matcher on the substituted fixture. stdout -> $OUT, exit -> $RC.
# Extra environment for the hook in the GATE_ENV array; RUN_MODE=broken runs
# with an empty environment and PATH=/nonexistent.
GATE_ENV=()
RUN_MODE=normal
run_gate() {
  local event="$1" matcher="$2" fixture="$3" cmd input; shift 3
  if ! cmd="$(hook_cmd "$event" "$matcher")"; then
    OUT=""; RC=99; echo "    (no single hooks.json entry for $event/$matcher)"; return
  fi
  input="$(payload "$fixture" "$@")"
  RC=0
  if [[ "$RUN_MODE" == broken ]]; then
    OUT="$(cd "$TEST_ROOT" && printf '%s' "$input" | env -i PATH=/nonexistent CLAUDE_PLUGIN_ROOT="$PLUGIN" ${GATE_ENV[@]+"${GATE_ENV[@]}"} "$SH" -c "$cmd" 2>"$TEST_ROOT/stderr")" || RC=$?
  else
    OUT="$(cd "$TEST_ROOT" && printf '%s' "$input" | env -u BASH CLAUDE_PLUGIN_ROOT="$PLUGIN" ${GATE_ENV[@]+"${GATE_ENV[@]}"} "$SH" -c "$cmd" 2>"$TEST_ROOT/stderr")" || RC=$?
  fi
}

# verdict: classify $OUT/$RC. deny = exit 0 + exactly the PreToolUse deny shape
# with a non-empty reason; allow = exit 0 + empty stdout; block = exit 0 +
# top-level decision block with a reason; context = exit 0 + UserPromptExpansion
# or PostToolUse additionalContext; else "other(...)".
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
elif isinstance(h, dict) and h.get("hookEventName") in ("UserPromptExpansion", "PostToolUse") and h.get("additionalContext"):
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
for py in /nonexistent "$TEST_ROOT/brokenpy" "$TEST_ROOT"; do
  GATE_ENV=("FABLEPOWERS_PYTHON=$py")
  run_gate PreToolUse Agent pre-agent CWD="$TEST_ROOT/nowhere" SUBAGENT=fablepowers:implementer
  expect "FABLEPOWERS_PYTHON=$py, no repo" warning
  check "  warning text" test "$OUT" == '{"systemMessage":"fablepowers approval gate disabled: python3 not found"}'
done
GATE_ENV=("FABLEPOWERS_PYTHON=/nonexistent")
RUN_MODE=broken
run_gate PreToolUse Agent pre-agent CWD="$R" SUBAGENT=fablepowers:implementer
expect "no python, empty PATH, pending design: first call warns (allowed)" warning
check "  warn-once marker written" test -e "$R/.fablepowers/.gate-warned-76496df1-bffc-49e9-96ae-c92ee405caf7"
run_gate PreToolUse Write pre-write CWD="$R" FILE="$R/src/app.py"
expect "no python, same session: second call silent" allow
RUN_MODE=normal
GATE_ENV=("FABLEPOWERS_PYTHON=$(command -v python3)")
check "FABLEPOWERS_PYTHON=<real python3> runs the gate" test "$(agent_verdict "$R" fablepowers:implementer)" == deny
# A python below 3.8 fails the launcher's version check: fake one by making
# sys.version_info's check exit 1 (as "import sys; sys.exit(True)" would).
printf '#!/bin/sh\ncase "$*" in *version_info*) exit 1 ;; esac\nexec python3 "$@"\n' > "$TEST_ROOT/py37"; chmod +x "$TEST_ROOT/py37"
GATE_ENV=("FABLEPOWERS_PYTHON=$TEST_ROOT/py37")
run_gate PreToolUse Agent pre-agent CWD="$TEST_ROOT/nowhere" SUBAGENT=fablepowers:implementer
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

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All approval-gate tests passed."
else
  echo "$FAILURES approval-gate test(s) failed."
  exit 1
fi
