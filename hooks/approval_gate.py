"""fablepowers design-approval gate (Claude Code hooks).

Run by hooks/approval-gate as `python3 -I approval_gate.py` with the hook
payload on stdin. Python 3.8+, stdlib only. Always exits 0; a decision is
expressed only through the JSON printed on stdout.

Markers live in <toplevel>/.fablepowers/<key>/, <key> being the spec's basename
without .md:
  pending   {"spec", "created"}                       written on a spec create
  approved  {"spec", "approved_at", "via", "spec_sha256"}
A design is pending iff `pending` exists and `approved` does not. <toplevel> is
the nearest ancestor of the payload's cwd holding a `.git` entry (a directory,
or a file in a linked worktree); outside a git repo the gate is inert.

Events (see hooks/hooks.json for the matchers):
  PreToolUse Agent|Write|Edit|MultiEdit|NotebookEdit  deny while pending; marker
                                                      writes are denied always
  PostToolUse Write                                   spec create -> pending
  PostToolUse AskUserQuestion                         Approve answer -> approved
  UserPromptExpansion fablepowers:approve|withdraw    user commands

FABLEPOWERS_GATE=off: never deny; would-be denials go to .fablepowers/gate.log.
Malformed payloads and internal errors allow (fail open) and are logged there.
"""

import datetime
import hashlib
import json
import os
import sys
import tempfile
import traceback

GATED_AGENTS = ("fablepowers:implementer", "fablepowers:strict-implementer")
EDIT_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
ALLOWED_DIRS = ("docs/specs", "docs/plans", ".fablepowers")
SPEC_DIR = "docs/specs"
MARKER_NAMES = ("pending", "approved")
QUESTION_LABELS = ("Approve", "Changes needed")


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")


def find_toplevel(cwd):
    """Nearest ancestor of cwd (realpath) with a .git entry, or None."""
    try:
        d = os.path.realpath(cwd)
    except (TypeError, ValueError):
        return None
    while True:
        if os.path.lexists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def under(path, directory):
    return path == directory or path.startswith(directory.rstrip(os.sep) + os.sep)


def fp_dir(top):
    return os.path.join(top, ".fablepowers")


def ensure_fp_dir(top):
    d = fp_dir(top)
    os.makedirs(d, exist_ok=True)
    gi = os.path.join(d, ".gitignore")
    if not os.path.lexists(gi):
        write_atomic(gi, "*\n")
    return d


def write_atomic(path, text):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_json(path, obj):
    write_atomic(path, json.dumps(obj, ensure_ascii=False, indent=2) + "\n")


def log(top, line):
    if not top:
        return
    try:
        ensure_fp_dir(top)
        with open(os.path.join(fp_dir(top), "gate.log"), "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (now(), line.replace("\n", " | ")))
    except OSError:
        pass


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def pending_designs(top):
    """[(key, spec)] for every design with pending and no approved, sorted."""
    d = fp_dir(top)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    out = []
    for key in names:
        kd = os.path.join(d, key)
        if not os.path.isdir(kd):
            continue
        if os.path.lexists(os.path.join(kd, "pending")) and not os.path.lexists(os.path.join(kd, "approved")):
            spec = read_json(os.path.join(kd, "pending")).get("spec")
            out.append((key, spec if isinstance(spec, str) and spec else key))
    return out


def key_list(pending):
    return ", ".join("%s (%s)" % (k, s) for k, s in pending)


def resolve(path, cwd):
    if not os.path.isabs(path):
        path = os.path.join(cwd, path)
    return os.path.realpath(path)


def is_marker_path(path):
    parts = path.split(os.sep)
    return len(parts) >= 2 and parts[-1] in MARKER_NAMES and ".fablepowers" in parts[:-1]


def spec_sha256(top, spec):
    try:
        with open(os.path.join(top, spec), "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except (OSError, TypeError, ValueError):
        return None


def record_approval(top, key, via):
    kd = os.path.join(fp_dir(top), key)
    spec = read_json(os.path.join(kd, "pending")).get("spec")
    if not isinstance(spec, str) or not spec:
        spec = None
    write_json(os.path.join(kd, "approved"), {
        "spec": spec,
        "approved_at": now(),
        "via": via,
        "spec_sha256": spec_sha256(top, spec) if spec else None,
    })
    return spec or key


def commands_hint(keys):
    k = keys[0] if len(keys) == 1 else "<key>"
    return ("ask the user to answer Approve to the approval question or run "
            "`/fablepowers:approve %s` (or `/fablepowers:withdraw %s` to abandon it)" % (k, k))


# --- PreToolUse -----------------------------------------------------------------

def deny(top, payload, reason):
    if os.environ.get("FABLEPOWERS_GATE", "") == "off":
        log(top, "FABLEPOWERS_GATE=off: would deny %s: %s" % (payload.get("tool_name"), reason))
        return
    emit({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }})


def pending_reason(pending, what):
    keys = [k for k, _ in pending]
    if len(pending) == 1:
        head = "Design `%s` awaits the user's approval" % pending[0][1]
    else:
        head = "Designs awaiting the user's approval: %s" % key_list(pending)
    return ("%s, so %s is blocked by the fablepowers approval gate. Stop and %s. "
            "Do not retry this call." % (head, what, commands_hint(keys)))


def pre_tool_use(top, payload, cwd):
    tool = payload.get("tool_name")
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        if tool in EDIT_TOOLS or tool == "Agent":
            log(top, "malformed PreToolUse %s payload (tool_input not an object); allowed" % tool)
        return
    if tool in EDIT_TOOLS:
        raw = ti.get("notebook_path" if tool == "NotebookEdit" else "file_path")
        if not isinstance(raw, str) or not raw:
            log(top, "PreToolUse %s without a path; allowed" % tool)
            return
        lexical = os.path.normpath(raw if os.path.isabs(raw) else os.path.join(cwd, raw))
        real = resolve(raw, cwd)
        if is_marker_path(lexical) or is_marker_path(real):
            deny(top, payload, "Approval markers (.fablepowers/**/pending, .fablepowers/**/approved) "
                 "are written only by the fablepowers approval gate on a user action; edit tools may "
                 "not create or change them. Ask the user to run `/fablepowers:approve` or "
                 "`/fablepowers:withdraw`. Do not retry this call.")
            return
        pending = pending_designs(top)
        if not pending or not under(real, top):
            return
        if any(under(real, os.path.realpath(os.path.join(top, d))) for d in ALLOWED_DIRS):
            return
        deny(top, payload, pending_reason(
            pending, "editing `%s` (only docs/specs/, docs/plans/ and .fablepowers/ are open "
            "until approval)" % os.path.relpath(real, top)))
    elif tool == "Agent":
        sub = ti.get("subagent_type")
        if sub in GATED_AGENTS:
            pending = pending_designs(top)
            if pending:
                deny(top, payload, pending_reason(pending, "dispatching `%s`" % sub))


# --- PostToolUse ------------------------------------------------------------------

def post_write(top, payload, cwd):
    if payload.get("agent_id"):
        return  # only main-session writes create pending
    tr = payload.get("tool_response")
    ti = payload.get("tool_input")
    if not isinstance(tr, dict) or tr.get("type") != "create":
        return
    raw = tr.get("filePath") or (ti.get("file_path") if isinstance(ti, dict) else None)
    if not isinstance(raw, str) or not raw:
        log(top, "PostToolUse Write create without a path; ignored")
        return
    real = resolve(raw, cwd)
    spec_dir = os.path.realpath(os.path.join(top, SPEC_DIR))
    if os.path.dirname(real) != spec_dir or not real.endswith(".md"):
        return
    key = os.path.basename(real)[:-3]
    if not key or key.startswith("."):
        return
    kd = os.path.join(fp_dir(top), key)
    if os.path.lexists(os.path.join(kd, "approved")) or os.path.lexists(os.path.join(kd, "pending")):
        return
    ensure_fp_dir(top)
    os.makedirs(kd, exist_ok=True)
    spec = os.path.relpath(real, top).replace(os.sep, "/")
    write_json(os.path.join(kd, "pending"), {"spec": spec, "created": now()})
    emit({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": (
            "fablepowers approval gate: design `%s` (key `%s`) is now pending the user's approval. "
            "Implementer dispatch and edits outside docs/specs/, docs/plans/ and .fablepowers/ are "
            "blocked until the user answers Approve or runs `/fablepowers:approve`." % (spec, key)),
    }})


def post_question(top, payload):
    tr = payload.get("tool_response")
    if not isinstance(tr, dict):
        return
    qs = tr.get("questions")
    answers = tr.get("answers")
    if not isinstance(qs, list) or not qs or not isinstance(qs[0], dict) or not isinstance(answers, dict):
        return
    q = qs[0]
    opts = q.get("options")
    if not isinstance(opts, list):
        return
    labels = [o.get("label") if isinstance(o, dict) else None for o in opts]
    if len(labels) != 2 or set(labels) != set(QUESTION_LABELS):
        return
    text = q.get("question")
    if not isinstance(text, str) or answers.get(text) != "Approve":
        return
    pending = pending_designs(top)
    if len(pending) == 1:
        key, spec = pending[0]
        if os.path.isfile(os.path.join(top, spec)):
            record_approval(top, key, "question")
            emit({"hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": "fablepowers approval gate: the user approved design `%s`; "
                                     "the approval is recorded." % spec,
            }})
            return
        why = "the spec file `%s` of the pending design no longer exists" % spec
    elif not pending:
        why = "no design is pending in this repository (no spec file under docs/specs/ was created)"
    else:
        why = "several designs are pending: %s" % key_list(pending)
    keys = [k for k, _ in pending]
    if keys:
        todo = "The user should run `/fablepowers:approve %s` (or `/fablepowers:withdraw %s`)." % (
            keys[0] if len(keys) == 1 else "<key>", keys[0] if len(keys) == 1 else "<key>")
    else:
        todo = "The gate is not blocking anything."
    msg = "fablepowers approval gate: the Approve answer was not recorded because %s. %s" % (why, todo)
    emit({
        "systemMessage": msg,
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": msg + " Tell the user this; do not ask the approval question again.",
        },
    })


# --- UserPromptExpansion ----------------------------------------------------------

def expansion_context(text):
    emit({"hookSpecificOutput": {"hookEventName": "UserPromptExpansion", "additionalContext": text}})


def pick(pending, arg):
    """The pending key the argument names, None for no match ('' arg = sole one)."""
    keys = [k for k, _ in pending]
    if not arg:
        return keys[0] if len(keys) == 1 else None
    if arg in keys:
        return arg
    base = os.path.basename(arg.rstrip("/"))
    if base.endswith(".md"):
        base = base[:-3]
    return base if base in keys else None


def user_command(top, payload):
    name = payload.get("command_name")
    if name not in ("fablepowers:approve", "fablepowers:withdraw"):
        return
    verb = "approve" if name == "fablepowers:approve" else "withdraw"
    arg = payload.get("command_args")
    arg = arg.strip() if isinstance(arg, str) else ""
    pending = pending_designs(top)
    if not pending:
        expansion_context("fablepowers approval gate: nothing is pending, so /fablepowers:%s "
                          "recorded nothing." % verb)
        return
    key = pick(pending, arg)
    if key is None:
        emit({"decision": "block", "reason": (
            "fablepowers approval gate: %s. Run `/fablepowers:%s <key>` with one of: %s. "
            "Nothing was recorded." % (
                ("no pending design matches `%s`" % arg) if arg else "several designs are pending",
                verb, key_list(pending)))})
        return
    spec = dict(pending)[key]
    if verb == "approve":
        record_approval(top, key, "command")
        expansion_context("fablepowers approval gate: the user approved design `%s` (key `%s`); "
                          "the approval is recorded." % (spec, key))
    else:
        os.remove(os.path.join(fp_dir(top), key, "pending"))
        expansion_context("fablepowers approval gate: the user withdrew design `%s` (key `%s`); "
                          "it is no longer pending." % (spec, key))


# --- main ---------------------------------------------------------------------------

def main():
    top = None
    try:
        raw = sys.stdin.read()
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = None
        if not isinstance(payload, dict):
            log(find_toplevel(os.getcwd()), "malformed hook payload (not a JSON object); allowed")
            return
        cwd = payload.get("cwd")
        if not isinstance(cwd, str) or not cwd:
            cwd = os.getcwd()
        top = find_toplevel(cwd)
        if not top:
            return
        event = payload.get("hook_event_name")
        tool = payload.get("tool_name")
        if event == "PreToolUse":
            pre_tool_use(top, payload, cwd)
        elif event == "PostToolUse" and tool == "Write":
            post_write(top, payload, cwd)
        elif event == "PostToolUse" and tool == "AskUserQuestion":
            post_question(top, payload)
        elif event == "UserPromptExpansion":
            user_command(top, payload)
    except Exception:
        log(top, "internal error, allowed: " + traceback.format_exc(limit=3))


if __name__ == "__main__":
    main()
    sys.exit(0)
