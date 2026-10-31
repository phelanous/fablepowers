#!/usr/bin/env bash
# Live eval driver (manual; not part of the offline suites). Bills your Claude
# Code login: each run is capped at $3 (--max-budget-usd) and a --max-turns cap.
#
# Usage: bash tests/evals/run-eval.sh <eval-name>     (eval6, eval6-resume, eval7, eval8, eval9, eval10)
#
# 1. Copies tests/evals/fixtures/<eval>/seed/ (or the seed of the fixture named
#    in its seed-from file) into a fresh `mktemp -d`, as a git repo on main.
#    Runs the fixture's setup.sh there, if any (env PLUGIN_ROOT, OUT, FIXTURE).
# 2. Runs headless `claude -p` in that repo with this checkout as --plugin-dir,
#    the installed fablepowers plugin disabled, acceptEdits plus a pattern
#    allowlist (see ALLOWED; never --dangerously-skip-permissions), and the
#    fixture's prompt.txt.
# 3. Saves into the output directory: stream.jsonl, the transcript
#    (session.jsonl plus session/subagents/), result.json, progress.md, the
#    repo's .fablepowers/ tree, git worktree list, git branch --list 'fp/*',
#    git status, info/exclude, .gitignore at HEAD, and main's history. Then
#    runs the fixture's post.sh, if any.
# 4. Runs the fixture's check.py (stdlib, -I) on the transcript and the
#    output directory; it uses scripts/session-timeline.py --json.
# 5. Prints each assertion and the run's cost; exits 0 on pass, 1 on fail,
#    2 on a usage or setup error.
#
# Env: CLAUDE_BIN (default claude); EVAL_OUT (output directory, default
# <tmp>/out); EVAL_MAX_BUDGET (a lower cap than $3); EVAL_RECHECK=<out-dir>
# re-runs only the checker on an earlier run's output. The temp directory is
# kept for inspection and its path printed; it holds the transcript, which can
# contain private data, so don't commit it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "usage: bash tests/evals/run-eval.sh <eval-name>" >&2
  exit 2
fi
EVAL="$1"
FIX="$SCRIPT_DIR/fixtures/$EVAL"
if [[ ! -f "$FIX/check.py" || ! -f "$FIX/prompt.txt" && -z "${EVAL_RECHECK:-}" ]]; then
  echo "run-eval: no such eval: $EVAL (expected $FIX/check.py and prompt.txt)" >&2
  exit 2
fi

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
  echo "run-eval: python3 >= 3.8 not found" >&2
  exit 2
fi

check() {
  local out="$1" rc=0
  "$PY" -I "$FIX/check.py" "$out/session.jsonl" "$out" || rc=$?
  "$PY" -I - "$out/result.json" <<'PYEOF' || true
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    r = {}
print("run: subtype=%s cost_usd=%s turns=%s permission_denials=%d" % (
    r.get("subtype"), r.get("total_cost_usd"), r.get("num_turns"), len(r.get("permission_denials") or [])))
for d in r.get("permission_denials") or []:
    print("  denied: %s %s" % (d.get("tool_name"), json.dumps(d.get("tool_input"))[:200]))
PYEOF
  echo "output: $out"
  return "$rc"
}

if [[ -n "${EVAL_RECHECK:-}" ]]; then
  rc=0; check "$EVAL_RECHECK" || rc=$?
  exit $(( rc ? 1 : 0 ))
fi

BUDGET=3
if [[ -n "${EVAL_MAX_BUDGET:-}" ]]; then
  BUDGET="$("$PY" -I -c 'import sys; print(min(3.0, float(sys.argv[1])))' "$EVAL_MAX_BUDGET")"
fi
MAX_TURNS="$(cat "$FIX/max-turns" 2>/dev/null || echo 60)"
SEED="$FIX/seed"
if [[ ! -d "$SEED" && -f "$FIX/seed-from" ]]; then
  SEED="$SCRIPT_DIR/fixtures/$(tr -d '[:space:]' < "$FIX/seed-from")/seed"
fi
if [[ ! -d "$SEED" ]]; then
  echo "run-eval: no seed for $EVAL" >&2
  exit 2
fi

T="$(mktemp -d)"
R="$T/repo"
OUT="${EVAL_OUT:-$T/out}"
mkdir -p "$R" "$OUT"
cp -a "$SEED/." "$R/"

# Isolate the fixture repo, and every git call the session makes, from the
# user's git config (signing, hooks, default branch names).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PYTHONDONTWRITEBYTECODE=1
git -C "$R" init -q -b main
git -C "$R" config user.name "Eval"
git -C "$R" config user.email "eval@example.invalid"
git -C "$R" config commit.gpgsign false
git -C "$R" add -A
git -C "$R" commit -qm "init"

if [[ -f "$FIX/setup.sh" ]]; then
  (cd "$R" && PLUGIN_ROOT="$REPO_ROOT" OUT="$OUT" FIXTURE="$FIX" bash "$FIX/setup.sh")
fi

# A pattern allowlist, as in the T0 spike. Edit tools are not listed: they
# stay under acceptEdits, so they write only inside the fixture repo. Known
# limit (Claude Code 2.1.306, -p): a command with a variable or a `( … )` group
# is denied under any pattern rule ("can't be checked before it runs"), and
# that includes the skills' marker pattern,
# `( cmd; echo "exit $?" > "$OUT.done" ) > "$OUT" 2>&1 &`. Denials are printed
# after the assertions; an agent that hits one has to find another way, and
# that is part of what eval 9 observes.
ALLOWED=(
  "Agent" "Read" "Glob" "Grep" "Skill"
  "TodoWrite" "TaskCreate" "TaskUpdate" "TaskList" "TaskGet" "TaskOutput" "BashOutput" "KillShell" "TaskStop"
  "Bash(git:*)" "Bash(bash:*)" "Bash(python3:*)" "Bash(cd:*)" "Bash(pwd)" "Bash(ls:*)" "Bash(cat:*)"
  "Bash(head:*)" "Bash(tail:*)" "Bash(grep:*)" "Bash(echo:*)" "Bash(printf:*)" "Bash(timeout:*)"
  "Bash(sleep:*)" "Bash(test:*)" "Bash([:*)" "Bash(wc:*)" "Bash(rm -f:*)" "Bash(mkdir:*)" "Bash(sed:*)"
  "Bash(kill:*)" "Bash(ps:*)" "Bash(pgrep:*)" "Bash(date:*)" "Bash(diff:*)" "Bash(sort:*)" "Bash(find:*)"
  "Bash(true)" "Bash(until:*)" "Bash(while:*)" "Bash(wait:*)"
)

echo "eval $EVAL: repo $R, budget \$$BUDGET, max turns $MAX_TURNS"
rc_claude=0
(cd "$R" && "${CLAUDE_BIN:-claude}" -p "$(cat "$FIX/prompt.txt")" \
  --allowedTools "${ALLOWED[@]}" \
  --plugin-dir "$REPO_ROOT" \
  --settings '{"enabledPlugins":{"fablepowers@fablepowers":false}}' \
  --permission-mode acceptEdits \
  --max-budget-usd "$BUDGET" --max-turns "$MAX_TURNS" \
  --output-format stream-json --verbose) > "$OUT/stream.jsonl" 2> "$OUT/stderr.txt" || rc_claude=$?
echo "claude exit status: $rc_claude"

SID="$("$PY" -I - "$OUT/stream.jsonl" "$OUT/result.json" <<'PYEOF'
import json, sys
sid, result = "", {}
for line in open(sys.argv[1], errors="replace"):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if isinstance(r, dict):
        sid = sid or r.get("session_id") or ""
        if r.get("type") == "result":
            result = r
json.dump(result, open(sys.argv[2], "w"))
print(sid)
PYEOF
)"

PROJ="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$R" | sed 's/[^A-Za-z0-9]/-/g')"
if [[ -n "$SID" && -f "$PROJ/$SID.jsonl" ]]; then
  cp "$PROJ/$SID.jsonl" "$OUT/session.jsonl"
  [[ -d "$PROJ/$SID" ]] && cp -a "$PROJ/$SID" "$OUT/session"
else
  echo "run-eval: transcript not found (session '$SID', looked in $PROJ)" >&2
  : > "$OUT/session.jsonl"
fi

# Captured state.
G() { git -C "$R" "$@" 2>/dev/null || true; }
progress="$(find "$R/.fablepowers" -mindepth 2 -maxdepth 2 -name progress.md 2>/dev/null | head -n 1)"
if [[ -n "$progress" ]]; then cp "$progress" "$OUT/progress.md"; else : > "$OUT/progress.md"; fi
[[ -d "$R/.fablepowers" ]] && cp -a "$R/.fablepowers" "$OUT/fablepowers"
G worktree list --porcelain > "$OUT/worktrees.txt"
G branch --list 'fp/*' > "$OUT/branches.txt"
G status --porcelain > "$OUT/status.txt"
cat "$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/info/exclude" > "$OUT/exclude.txt" 2>/dev/null || : > "$OUT/exclude.txt"
G show HEAD:.gitignore > "$OUT/gitignore-head.txt"
G log --format='%H %P|%s' main > "$OUT/log.txt"
G rev-list --first-parent main > "$OUT/first-parent.txt"
if [[ -f "$FIX/post.sh" ]]; then
  (cd "$R" && PLUGIN_ROOT="$REPO_ROOT" OUT="$OUT" FIXTURE="$FIX" bash "$FIX/post.sh") || true
fi

rc=0
check "$OUT" || rc=$?
echo "kept: $T"
exit $(( rc ? 1 : 0 ))
