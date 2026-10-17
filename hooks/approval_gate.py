"""fablepowers design-approval gate (Claude Code hooks).

Run by hooks/approval-gate as `python3 -I approval_gate.py` with the hook
payload on stdin. Python 3.8+, stdlib only. Always exits 0; a decision is
expressed only through the JSON printed on stdout.

Markers live in <toplevel>/.fablepowers/<key>/, <key> being the spec's basename
without .md:
  pending   {"spec", "created"}                       written on a spec create
  approved  {"spec", "approved_at", "via", "spec_sha256"}
A design is pending iff `pending` is a regular file (not a symlink) and there
is no valid `approved`: a regular, non-symlink file holding a JSON object with
`via` ("command" or "question"), a non-empty string `approved_at` and a `spec`
(string or null). Anything else named `approved` (a directory, a symlink,
invalid JSON) is a forgery: it is ignored and logged. <toplevel> is
the nearest ancestor of the payload's cwd holding a `.git` entry (a directory,
or a file in a linked worktree); outside a git repo the gate is inert.

Events (see hooks/hooks.json for the matchers):
  PreToolUse Agent|Write|Edit|MultiEdit|NotebookEdit  deny while pending; marker
                                                      writes are denied always
  PostToolUse Write                                   spec create -> pending
  PostToolUse AskUserQuestion                         Approve answer -> approved
  UserPromptExpansion fablepowers:approve|withdraw    user commands

Edit-tool writes through any path with a marker-named component under a
`.fablepowers` component are denied, names compared case-insensitively and
NTFS-normalised (trailing dots/spaces and `:stream` suffixes ignored). While any
design is pending, edit-tool writes to a Claude Code settings file
(`.claude/settings.json` or `.claude/settings.local.json`, anywhere, the repo
and ~/.claude included) are denied too, the path tail compared the same way,
through the lexical path and through symlinks. Shell (Bash) writes are not
intercepted: an accepted gap, documented in the Claude Code harness reference.

Codex branch. A payload is Codex's iff its tool_name is apply_patch,
collaborationspawn_agent (multi-agent v2) or spawn_agent (v1), or it is a
UserPromptSubmit carrying `turn_id`; everything else takes the Claude Code
logic above, unchanged. Same markers, states and rules:
  PreToolUse apply_patch (Codex routes it through the Write and Edit matchers)
      every Add/Update/Delete/Move-to path of the patch, resolved against the
      payload cwd, is checked like an edit-tool path: markers denied always;
      while pending, Codex config (`.codex/config.toml`, `.codex/rules/`,
      `.codex/agents/`, `.codex/hooks*`, anywhere, and $CODEX_HOME/config.toml)
      denied, and repo paths outside the allowlist denied; one bad path denies
      the whole patch. The patch is split into lines on "\n" only and each
      line is trimmed before header matching, as Codex's own parser does (it
      accepts indented headers and CRLF); a header path is taken as Codex takes
      it (see parse_patch). A patch the gate cannot parse is denied while
      pending (fail closed), else allowed and logged; so is a header path
      holding a control character (C0, DEL, C1, U+2028, U+2029: \v, \f and
      \x1c-\x1e included) or one that cannot be resolved, and such a path is
      denied always when it could name a marker (`.fablepowers` and
      `pending`/`approved` in it, with or without its control characters, or
      resolving to a marker through a symlink), so it never masks the other
      paths of the patch.
  PreToolUse collaborationspawn_agent | spawn_agent   while pending, allowed only
      for a reviewer: v2 task_name `fablepowers_reviewer` or
      `fablepowers_reviewer_*`; v1 message whose first line is
      `fablepowers-seat: reviewer`. Every other spawn is denied.
  PostToolUse apply_patch   an `*** Add File:` of docs/specs/<name>.md that the
      tool response confirms (`A <path>` line), or an `*** Update File:` with
      `*** Move to:` docs/specs/<name>.md confirmed by `M <destination>`, from
      the main session (no agent_id) -> pending. Add File also overwrites, so
      rewriting a spec that has no markers re-pends it (Claude Code's Write
      update does not); an already approved or pending key is left alone, as
      on Claude Code.
  UserPromptSubmit (turn_id, no agent_id)   the whole prompt matching
      `$fablepowers:approve|withdraw [key]` approves / withdraws. On Codex a
      block reason never reaches the model or an exec user, so every answer is
      additionalContext; several pending without a key records nothing. A
      prompt that starts with `$fablepowers:approve|withdraw` but does not match
      records nothing and gets a "not recognised" context.
Codex deny messages name `$fablepowers:approve [key]` (no question path) and
end with the recovery line (trust the hooks in /hooks, or FABLEPOWERS_GATE=off),
with no final period since Codex appends ". Tool: <name>".

OpenCode branch. A payload is OpenCode's iff `harness` is "opencode"; the JS
adapter (opencode/index.js) builds it and runs this file directly. Every
payload has `hook`, `cwd` (the session directory, absolute; anything else makes
the gate inert), `session_id`, `parent_id` (null for a root session) and `plugin_root`;
when the adapter cannot look up the parent it sends `parent_id` null plus
`parent_unknown: true`. Pending creation treats that as root (a design is
never missed); approve/withdraw (prompt, command, question) record only for a
session positively known to be root (`parent_id` null, no `parent_unknown`)
and otherwise answer with a "recorded nothing" context. The
answer is always exactly one JSON object on stdout: `{}` (no decision; also on
an internal error), `{"decision": "deny", "reason": <text>}` (permission,
before) or `{"context": <text>}` (after, prompt, command). Same markers, states
and rules:
  permission (permission.evaluate)  `action` "edit": every path in `resources`
      and `files[].file`, resolved against cwd, is checked like an edit-tool
      path: markers denied always; while pending, OpenCode config denied
      (`opencode.json`/`opencode.jsonc` anywhere, anything under a `.opencode`
      directory, `<config home>/opencode/` and `<config home>/fablepowers/
      models.toml`, config home being $XDG_CONFIG_HOME and ~/.config), then
      repo paths inside the allowlist pass, paths under `plugin_root` are
      denied (config-home, models.toml and plugin-root prefixes compared per
      component as win_name() normalises them), other paths outside the toplevel pass, and the rest is denied;
      one bad path denies the call; no usable path denies while pending.
      `action` "subagent": while pending, every resource (the agent that will
      run, continuations included) must be `fablepowers-reviewer` or
      `explore`. Other actions: no decision.
  before (tool.execute.before)  tool `subagent`: the same dispatch rule on
      `input.agent`. Other tools: no decision.
  after (tool.execute.after, `status` "completed" only)  from a root session:
      `write` with `output.existed` false, `edit` with an `output.files[]`
      entry whose status is "added", and `patch` `output.applied[]` adds whose
      target the adapter recorded as not existing before the call (`existed`,
      {<path>: bool}, paths absolute or relative to cwd; matched against the
      entry's `target` or `resource`, lexically or by realpath), and `patch`
      `output.applied[]` updates whose target is a `*** Move to:` destination
      of `input.patchText` (a move, as on Codex), make a
      docs/specs/<name>.md pending, with a notice. Tool `question`: exactly one
      question whose option labels are exactly Approve and Changes needed,
      answered exactly ["Approve"], with exactly one pending design whose spec
      exists, from a known root session -> approved (via question); a
      matching Approve that cannot be recorded gets a "not recorded" context.
  prompt  `text` (the adapter strips one wrapping pair of
      quotes) matching `/fablepowers:approve|withdraw [key]` as the whole text
      approves / withdraws; text that starts like the command (leading quotes
      allowed) but does not match gets a "not recognised" context; either
      from a session not known to be root gets a "recorded nothing" context.
  command  `verb` ("approve"/"withdraw") and `args` (the key, if any); known
      root sessions only, as for prompt.
OpenCode messages name `/fablepowers:approve [key]` and the approval question;
an approve result carries the next workflow step.

Pi branch. A payload is Pi's iff `harness` is "pi"; the extension
(pi/fablepowers.ts) builds it and runs this file directly. Every payload has
`hook`, `cwd` (ctx.cwd, absolute; anything else makes the gate inert),
`session_id`, `is_child` (bool), `plugin_root`, `mode` ("tui", "print", "json",
"rpc"), `env_session` (bool: PI_SESSION_ID in the extension's environment) and,
when $PI_CODING_AGENT_DIR is set, `pi_agent_dir`. Paths arrive absolute (the
extension resolves `@`, `~` and `file://` as Pi does). The answer is exactly one
JSON object: `{}` (no decision; also on an internal error), `{"decision": "deny",
"reason"}` (tool_call, dispatch), `{"context"}` (tool_result, approval_tool,
command) or, for `pending`, `{"pending": [{"key", "spec"}], "refused", "reason"}`.
Approve/withdraw (command and approval tool) are refused when `is_child` is not
exactly false, or when `env_session` is not exactly false, in every mode
including "tui" (both fail closed). Same markers, states and rules:
  tool_call  `tool` "write" or "edit" only (reads are never gated), `path`:
      markers denied always; while pending, Pi config denied (anything under a
      `.pi` directory, under `pi_agent_dir`, and <config home>/fablepowers/
      models.toml), then repo paths inside the allowlist pass, paths under
      `plugin_root` are denied, other paths outside the toplevel pass, and the
      rest is denied. A missing or relative path is logged and denied while
      pending (and always when it looks like a marker).
  tool_result  `tool` "write", `is_error` false, not `is_child`: `existed`
      (recorded by the extension at tool_call) false, or missing (logged), on a
      docs/specs/<name>.md -> pending, with a notice.
  dispatch  while pending: `tool` "fablepowers_dispatch" allowed only for `seat`
      "reviewer"; `tool` "subagent" (Pi's example) denied whatever its `agent`.
  pending  read-only: the pending designs and the refusal; writes nothing.
  approval_tool  `choice` ("Approve", "Changes needed" or null) and
      `pending_key`: Approve records (via question) only when the key is still
      pending, its spec exists and the session is not refused.
  command  `verb` ("approve"/"withdraw") and `args` (the key, if any).
Pi messages name `fablepowers_ask_approval` and `/fablepowers:approve [key]`;
an approve result carries the next workflow step (Pi skill names).

FABLEPOWERS_GATE=off: never deny; would-be denials go to .fablepowers/gate.log.
Malformed payloads and internal errors allow (fail open) and are logged there.
"""

import datetime
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import traceback

GATED_AGENTS = ("fablepowers:implementer", "fablepowers:strict-implementer")
EDIT_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
ALLOWED_DIRS = ("docs/specs", "docs/plans", ".fablepowers")
SPEC_DIR = "docs/specs"
MARKER_NAMES = ("pending", "approved")
SETTINGS_NAMES = ("settings.json", "settings.local.json")
QUESTION_LABELS = ("Approve", "Changes needed")

# Codex
CODEX_SPAWN_TOOLS = ("collaborationspawn_agent", "spawn_agent")
CODEX_TOOLS = ("apply_patch",) + CODEX_SPAWN_TOOLS
PATCH_BEGIN = "*** Begin Patch"
# A patch file-operation header after trimming the line. Deliberately looser than
# Codex (case, spacing): a header the gate over-recognises only adds a checked path.
PATCH_HEADER = re.compile(r"\*\*\*[ \t]*(add file|update file|delete file|move to)[ \t]*:(.*)",
                          re.IGNORECASE)
REVIEWER_TASK = "fablepowers_reviewer"
REVIEWER_SEAT_LINE = re.compile(r"fablepowers-seat:[ \t]*reviewer")
# One trailing newline (LF or CRLF) is accepted, in case a client submits it.
CODEX_COMMAND = re.compile(r"[ \t]*\$fablepowers:(approve|withdraw)(?:[ \t]+(\S+))?[ \t]*(?:\r?\n)?")
# A prompt that starts like a command but is not one gets a "not recognised" hint.
CODEX_NEAR_MISS = re.compile(r"\s*\$fablepowers:(approve|withdraw)")
CODEX_CONFIG_DIRS = ("rules", "agents")
CODEX_RECOVERY = ("If the user's approval does not register, the fablepowers hooks may be "
                  "untrusted: trust them in `/hooks`, or set `FABLEPOWERS_GATE=off` to turn the gate off")
# No final period: Codex appends ". Tool: <name>" to a PreToolUse deny reason.
# A header path holding one of these (C0/C1 controls, DEL, U+2028, U+2029) is not
# checked as a path: it fails closed (denied while pending, and always when it
# looks like a marker or resolves to one).
PATH_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]")
# The characters Rust's str::trim removes (Unicode White_Space). Codex trims each
# patch line with it; Python's str.strip also removes \x1c-\x1f.
RUST_WS = ("\t\n\x0b\x0c\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007"
           "\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000")
CODEX_HOW = ("type it as a message (or pick it from the `$` menu in the CLI); in the Codex app, "
             "type it as text")

# OpenCode
OC_ALLOWED_AGENTS = ("fablepowers-reviewer", "explore")
OC_CONFIG_NAMES = ("opencode.json", "opencode.jsonc")
# One trailing newline (LF or CRLF) is accepted, as on Codex.
OC_COMMAND = re.compile(r"[ \t]*/fablepowers:(approve|withdraw)(?:[ \t]+(\S+))?[ \t]*(?:\r?\n)?")
# A text that starts like a command (leading quotes the adapter left count) gets a hint.
OC_NEAR_MISS = re.compile(r"\s*[\"']*/fablepowers:(approve|withdraw)")
OC_NEXT_STEP = ("Tell the user in one line which design, then continue the workflow: write the "
                "implementation plan with fablepowers:implementation-plan (or, when the approved design "
                "already has a plan, execute it).")


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


def is_regular_file(path):
    """True for a regular file that is not a symlink."""
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def valid_approved(path):
    """True iff `path` is a gate-written approval: a regular, non-symlink file
    holding a JSON object with the expected fields."""
    if not is_regular_file(path):
        return False
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
    except (OSError, ValueError):
        return False
    return (isinstance(v, dict)
            and v.get("via") in ("command", "question")
            and isinstance(v.get("approved_at"), str) and bool(v["approved_at"])
            and "spec" in v and (v["spec"] is None or isinstance(v["spec"], str)))


def pending_designs(top):
    """[(key, spec)] for every design with a pending file and no valid approved, sorted.
    An invalid `approved` (forged) does not count and is logged."""
    d = fp_dir(top)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    out = []
    for key in names:
        kd = os.path.join(d, key)
        if not os.path.isdir(kd) or not is_regular_file(os.path.join(kd, "pending")):
            continue
        a = os.path.join(kd, "approved")
        if valid_approved(a):
            continue
        if os.path.lexists(a):
            log(top, "invalid approved marker for `%s` ignored (not a regular file with the "
                     "gate's JSON); the design stays pending" % key)
        spec = read_json(os.path.join(kd, "pending")).get("spec")
        out.append((key, spec if isinstance(spec, str) and spec else key))
    return out


def key_list(pending):
    return ", ".join("%s (%s)" % (k, s) for k, s in pending)


def resolve(path, cwd):
    if not os.path.isabs(path):
        path = os.path.join(cwd, path)
    return os.path.realpath(path)


def win_name(part):
    """A path component as Windows/NTFS resolves it, casefolded: anything from the
    first ':' dropped (`approved:s` and `approved::$DATA` name a stream of
    `approved`), then trailing dots and spaces stripped (`approved.` and
    `approved ` open `approved`)."""
    return part.split(":", 1)[0].rstrip(". ").casefold()


def is_marker_path(path):
    """True when any component after a `.fablepowers` component is a marker name.
    Components are compared as win_name() normalises them: case-insensitive
    filesystems resolve `.FablePowers/k/Approved` to the marker, NTFS also
    `approved.`, `approved ` and `approved:stream`; `approved/x` would create a
    directory named like it."""
    parts = [win_name(p) for p in path.split(os.sep)]
    fp = ".fablepowers".casefold()
    markers = {m.casefold() for m in MARKER_NAMES}
    if fp not in parts:
        return False
    return any(p in markers for p in parts[parts.index(fp) + 1:])


def is_settings_path(path):
    """True when the path ends in `.claude/settings.json` or
    `.claude/settings.local.json`, components normalised as win_name() does."""
    parts = [win_name(p) for p in path.split(os.sep)]
    return (len(parts) >= 2 and parts[-2] == ".claude".casefold()
            and parts[-1] in {n.casefold() for n in SETTINGS_NAMES})


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
        if not pending:
            return
        if is_settings_path(lexical) or is_settings_path(real):
            deny(top, payload, pending_reason(
                pending, "editing the Claude Code settings file `%s` (settings files stay closed "
                "to the edit tools until approval; if the user asked for this settings change, they can "
                "make it themselves, or approve or withdraw the design first)" % lexical))
            return
        inside = in_repo(real, top)
        if inside is None:
            return
        if any(under(inside, os.path.realpath(os.path.join(top, d))) for d in ALLOWED_DIRS):
            return
        deny(top, payload, pending_reason(
            pending, "editing `%s` (only docs/specs/, docs/plans/ and .fablepowers/ are open "
            "until approval)" % os.path.relpath(inside, top)))
    elif tool == "Agent":
        sub = ti.get("subagent_type")
        if sub in GATED_AGENTS:
            pending = pending_designs(top)
            if pending:
                deny(top, payload, pending_reason(pending, "dispatching `%s`" % sub))


# --- PostToolUse ------------------------------------------------------------------

def mark_pending(top, real):
    """Write the pending marker for the spec at realpath `real` when it is a
    docs/specs/<name>.md whose key has no pending or valid approved marker yet.
    Returns (spec, key) when it wrote one, else None.

    The directory is compared per component as win_parts() normalises it, so a
    spec created through a case or NTFS-name variant of the toplevel or of
    docs/specs (which a case-insensitive filesystem resolves to docs/specs itself)
    still goes pending; on a case-sensitive filesystem that over-marks, the safe
    side. The name counts as `.md` case-insensitively, as written or with its
    NTFS stream suffix and trailing dots/spaces dropped; the key keeps its case.
    The spec path is recorded as written, under top when in_repo() places it."""
    spec_dir = os.path.realpath(os.path.join(top, SPEC_DIR))
    if win_parts(os.path.dirname(real)) != win_parts(spec_dir):
        return None
    name = os.path.basename(real)
    key = None
    for cand in (name, name.split(":", 1)[0].rstrip(". ")):
        if cand[-3:].casefold() == ".md":
            key = cand[:-3]
            break
    if not key or key.startswith("."):
        return None
    kd = os.path.join(fp_dir(top), key)
    if valid_approved(os.path.join(kd, "approved")) or is_regular_file(os.path.join(kd, "pending")):
        return None
    for m in MARKER_NAMES:
        if os.path.lexists(os.path.join(kd, m)):
            log(top, "invalid %s marker for `%s` ignored on spec create" % (m, key))
    ensure_fp_dir(top)
    os.makedirs(kd, exist_ok=True)
    spec = os.path.relpath(in_repo(real, top) or real, top).replace(os.sep, "/")
    write_json(os.path.join(kd, "pending"), {"spec": spec, "created": now()})
    return spec, key


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
    made = mark_pending(top, resolve(raw, cwd))
    if not made:
        return
    spec, key = made
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


# --- Codex ----------------------------------------------------------------------------

def is_codex(payload):
    return (payload.get("tool_name") in CODEX_TOOLS
            or (payload.get("hook_event_name") == "UserPromptSubmit" and "turn_id" in payload))


def codex_commands_hint(keys):
    k = keys[0] if len(keys) == 1 else "<key>"
    return ("ask the user to approve it by sending `$fablepowers:approve %s` (or `$fablepowers:withdraw %s` "
            "to abandon it): %s. There is no approval question on Codex; end your turn after asking"
            % (k, k, CODEX_HOW))


def codex_pending_reason(pending, what):
    keys = [k for k, _ in pending]
    if len(pending) == 1:
        head = "Design `%s` awaits the user's approval" % pending[0][1]
    else:
        head = "Designs awaiting the user's approval: %s" % key_list(pending)
    return ("%s, so %s is blocked by the fablepowers approval gate. Stop and %s. "
            "Do not retry this call. %s" % (head, what, codex_commands_hint(keys), CODEX_RECOVERY))


def codex_patch_text(ti):
    """The apply_patch patch: tool_input.command (Codex 0.162.1, v1 and v2), else
    any string field holding `*** Begin Patch`, or tool_input itself when it is
    such a string. None when there is none."""
    if isinstance(ti, str):
        return ti if PATCH_BEGIN in ti else None
    if not isinstance(ti, dict):
        return None
    v = ti.get("command")
    if isinstance(v, str) and PATCH_BEGIN in v:
        return v
    for k in sorted(ti, key=str):
        v = ti[k]
        if isinstance(v, str) and PATCH_BEGIN in v:
            return v
    return None


def parse_patch(text):
    """[(op, path)] for every file-operation header in the patch; None when there
    is no header or a header has an empty path.

    Lines are split on "\n" only, as Codex splits them (str.splitlines would also
    split on \v, \f, \x1c-\x1e, \x85, U+2028 and U+2029, hiding the rest of a
    header path from the gate). A header is recognised on the line trimmed with
    str.strip (a superset of Codex's trim, so indented and CRLF headers count).
    The path is taken as Codex 0.162.1 takes it (checked against its parser):
    everything after the header's ": " up to the end of the line trimmed of
    Unicode whitespace, untrimmed at its start, so `*** Add File:   x` names
    `  x` and a trailing \x1c stays part of the name."""
    ops = []
    for line in text.split("\n"):
        if line.endswith("\r"):
            line = line[:-1]
        m = PATCH_HEADER.fullmatch(line.strip())
        if not m:
            continue
        tail = line.rstrip(RUST_WS)
        tail = tail[tail.index(":") + 1:]
        path = tail[1:] if tail.startswith(" ") else tail
        if not path.strip():
            return None
        ops.append((m.group(1).lower(), path))
    return ops or None


def is_codex_config_path(path):
    """True for a Codex config file: `.codex/config.toml`, anything under
    `.codex/rules/` or `.codex/agents/`, `.codex/hooks*` (any location, components
    normalised as win_name() does), and $CODEX_HOME/config.toml."""
    parts = [win_name(p) for p in path.split(os.sep)]
    for i in range(len(parts) - 1):
        if parts[i] == ".codex":
            nxt = parts[i + 1]
            if nxt == "config.toml" or nxt in CODEX_CONFIG_DIRS or nxt.startswith("hooks"):
                return True
    home = os.environ.get("CODEX_HOME", "")
    if home and parts and parts[-1] == "config.toml":
        d = os.path.dirname(path)
        try:
            return (os.path.normpath(d) == os.path.normpath(os.path.abspath(home))
                    or os.path.realpath(d) == os.path.realpath(home))
        except (TypeError, ValueError):
            return False
    return False


def shown_path(p):
    """A header path for a message or the log: control characters and anything
    not ASCII shown as backslash escapes (a NUL or lone surrogate must not reach
    the JSON output or the log file as itself)."""
    out = []
    for c in p:
        if " " <= c <= "~":
            out.append(c)
        elif ord(c) <= 0xff:
            out.append("\\x%02x" % ord(c))
        else:
            out.append(c.encode("ascii", "backslashreplace").decode("ascii"))
    return "".join(out)


def unchecked_marker(p, cwd):
    """For a header path the gate does not check as a path (a control character):
    True when it could name a marker, judged by substrings of the path as given
    and with its control characters removed, or by the marker check on those two
    paths resolved (a symlink whose name holds a control character can lead into
    .fablepowers/<key>/)."""
    if is_marker_like(p):
        return True
    for v in (p, PATH_CONTROL.sub("", p)):
        try:
            if is_marker_path(os.path.normpath(os.path.join(cwd, v))) or is_marker_path(resolve(v, cwd)):
                return True
        except (ValueError, OSError, TypeError):
            continue
    return False


def is_marker_like(p):
    """For a header path the gate cannot resolve: True when it could name a marker,
    as given or with its control characters removed, judged by substrings
    (casefolded `.fablepowers` and `pending` or `approved`), so it errs on denying."""
    for v in (p, PATH_CONTROL.sub("", p)):
        v = v.casefold()
        if ".fablepowers" in v and any(m in v for m in MARKER_NAMES):
            return True
    return False


def codex_pre_apply_patch(top, payload, cwd):
    text = codex_patch_text(payload.get("tool_input"))
    ops = parse_patch(text) if text is not None else None
    if ops is None:
        why = "no `*** Begin Patch` text in tool_input" if text is None else "no file operation header with a path"
        pending = pending_designs(top)
        if pending:
            deny(top, payload, codex_pending_reason(
                pending, "this apply_patch call (the gate could not parse its patch: %s, so it cannot "
                "check the paths and fails closed)" % why))
        else:
            log(top, "Codex apply_patch without a parseable patch (%s); allowed" % why)
        return
    paths, unchecked = [], []
    for _, p in ops:
        if PATH_CONTROL.search(p):
            unchecked.append((p, "it holds a control character"))
            continue
        try:
            paths.append((p, os.path.normpath(os.path.join(cwd, p)), resolve(p, cwd)))
        except (ValueError, OSError, TypeError):
            unchecked.append((p, "it cannot be resolved"))
    marker_deny = ("Approval markers (.fablepowers/**/pending, .fablepowers/**/approved) "
                   "are written only by the fablepowers approval gate on a user action; apply_patch may "
                   "not create, change or delete them (`%s`). Ask the user to send `$fablepowers:approve` "
                   "or `$fablepowers:withdraw`: %s. Do not retry this call. %s")
    for p, _ in unchecked:
        if unchecked_marker(p, cwd):
            deny(top, payload, marker_deny % (shown_path(p), CODEX_HOW, CODEX_RECOVERY))
            return
    for p, lexical, real in paths:
        if is_marker_path(lexical) or is_marker_path(real):
            deny(top, payload, marker_deny % (p, CODEX_HOW, CODEX_RECOVERY))
            return
    pending = pending_designs(top)
    if not pending:
        for p, why in unchecked:
            log(top, "Codex apply_patch header path `%s` the gate cannot check (%s); allowed, nothing "
                "pending" % (shown_path(p), why))
        return
    if unchecked:
        p, why = unchecked[0]
        deny(top, payload, codex_pending_reason(
            pending, "this patch (the gate cannot check its path `%s`: %s, so it fails closed)"
            % (shown_path(p), why)))
        return
    for p, lexical, real in paths:
        if is_codex_config_path(lexical) or is_codex_config_path(real):
            deny(top, payload, codex_pending_reason(
                pending, "patching the Codex config file `%s` (Codex config, rules, agents and hooks "
                "stay closed to apply_patch until approval; if the user asked for this change, they can "
                "make it themselves, or approve or withdraw the design first)" % lexical))
            return
    allowed = [os.path.realpath(os.path.join(top, d)) for d in ALLOWED_DIRS]
    inside = [in_repo(real, top) for _, _, real in paths]
    bad = [os.path.relpath(i, top) for i in inside
           if i is not None and not any(under(i, a) for a in allowed)]
    if bad:
        deny(top, payload, codex_pending_reason(
            pending, "this patch (it touches %s; only docs/specs/, docs/plans/ and .fablepowers/ are "
            "open until approval, and one such path denies the whole patch)"
            % ", ".join("`%s`" % b for b in bad)))


def codex_pre_spawn(top, payload, tool):
    pending = pending_designs(top)
    if not pending:
        return
    ti = payload.get("tool_input")
    ti = ti if isinstance(ti, dict) else {}
    if tool == "collaborationspawn_agent":
        name = ti.get("task_name")
        if isinstance(name, str) and (name == REVIEWER_TASK or name.startswith(REVIEWER_TASK + "_")):
            return
        what = ("spawning agent `%s`" % name) if isinstance(name, str) and name else "spawning an unnamed agent"
    else:
        msg = ti.get("message")
        first = msg.split("\n", 1)[0].strip() if isinstance(msg, str) else ""
        if REVIEWER_SEAT_LINE.fullmatch(first):
            return
        what = "spawning an agent that is not a fablepowers reviewer"
    deny(top, payload, codex_pending_reason(
        pending, "%s (until approval only reviewer spawns pass: v2 task_name `%s_<suffix>`, v1 "
        "message first line `fablepowers-seat: reviewer`)" % (what, REVIEWER_TASK)))


def codex_post_apply_patch(top, payload, cwd):
    if payload.get("agent_id"):
        return  # only main-session patches create pending
    text = codex_patch_text(payload.get("tool_input"))
    ops = parse_patch(text) if text is not None else None
    if ops is None:
        log(top, "PostToolUse Codex apply_patch without a parseable patch; ignored")
        return
    tr = payload.get("tool_response")
    if not isinstance(tr, str):
        log(top, "PostToolUse Codex apply_patch with a non-string tool_response; no spec marked pending")
        return
    applied = {line.strip(RUST_WS) for line in tr.split("\n")}
    made = []
    for op, p in ops:
        # An Add shows `A <path>`; a Move shows `M <destination>` (Update + Move to).
        if not ((op == "add file" and ("A " + p).strip(RUST_WS) in applied)
                or (op == "move to" and ("M " + p).strip(RUST_WS) in applied)):
            continue
        m = mark_pending(top, resolve(p, cwd))
        if m:
            made.append(m)
    if not made:
        return
    names = ", ".join("`%s` (key `%s`)" % m for m in made)
    emit({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": (
            "fablepowers approval gate: design %s %s now pending the user's approval. Implementer "
            "spawns and patches outside docs/specs/, docs/plans/ and .fablepowers/ are blocked until the "
            "user sends `$fablepowers:approve%s`: %s. There is no approval question on Codex: present the "
            "design, ask the user to reply with that command, and end your turn." % (
                names, "is" if len(made) == 1 else "are",
                "" if len(made) == 1 else " <key>", CODEX_HOW)),
    }})


ACT_NOUN = {"approve": "an approval", "withdraw": "a withdrawal"}


def codex_context(text):
    emit({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": text}})


def codex_user_prompt(top, payload):
    if "agent_id" in payload:
        return  # a subagent's prompt is the spawn message, never the user's command
    prompt = payload.get("prompt")
    if not isinstance(prompt, str):
        return
    m = CODEX_COMMAND.fullmatch(prompt)
    if not m:
        near = CODEX_NEAR_MISS.match(prompt)
        if near:
            verb = near.group(1)
            codex_context(
                "fablepowers approval gate: `$fablepowers:%s` was not recognised, so it recorded "
                "nothing; send exactly `$fablepowers:%s [key]` on its own, as the whole message. "
                "Tell the user this; do not act on this message as %s." % (verb, verb, ACT_NOUN[verb]))
        return
    verb, arg = m.group(1), m.group(2) or ""
    pending = pending_designs(top)
    if not pending:
        codex_context("fablepowers approval gate: nothing is pending, so `$fablepowers:%s` recorded "
                      "nothing." % verb)
        return
    key = pick(pending, arg)
    if key is None:
        codex_context(
            "fablepowers approval gate: %s, so `$fablepowers:%s` recorded nothing. Tell the user to "
            "send `$fablepowers:%s <key>` with one of: %s. Do not act on this message as %s." % (
                ("no pending design matches `%s`" % arg) if arg else "several designs are pending",
                verb, verb, key_list(pending), ACT_NOUN[verb]))
        return
    spec = dict(pending)[key]
    if verb == "approve":
        record_approval(top, key, "command")
        codex_context("fablepowers approval gate: the user approved design `%s` (key `%s`); "
                      "the approval is recorded." % (spec, key))
    else:
        os.remove(os.path.join(fp_dir(top), key, "pending"))
        codex_context("fablepowers approval gate: the user withdrew design `%s` (key `%s`); "
                      "it is no longer pending." % (spec, key))


# --- OpenCode -------------------------------------------------------------------------

def oc_commands_hint(keys):
    k = keys[0] if len(keys) == 1 else "<key>"
    return ("ask the user to answer Approve to the approval question, or to run `/fablepowers:approve %s` "
            "(or `/fablepowers:withdraw %s` to abandon it) as a command or as the whole message" % (k, k))


def oc_pending_reason(pending, what):
    keys = [k for k, _ in pending]
    if len(pending) == 1:
        head = "Design `%s` awaits the user's approval" % pending[0][1]
    else:
        head = "Designs awaiting the user's approval: %s" % key_list(pending)
    return ("%s, so %s is blocked by the fablepowers approval gate. Stop and %s. "
            "Do not retry this call." % (head, what, oc_commands_hint(keys)))


def oc_deny(top, payload, reason):
    if os.environ.get("FABLEPOWERS_GATE", "") == "off":
        log(top, "FABLEPOWERS_GATE=off: would deny OpenCode %s: %s" % (payload.get("hook"), reason))
        return {}
    return {"decision": "deny", "reason": reason}


def oc_config_homes():
    """The config homes the guard covers: $XDG_CONFIG_HOME (when absolute) and ~/.config."""
    homes = []
    x = os.environ.get("XDG_CONFIG_HOME", "")
    if x and os.path.isabs(x):
        homes.append(x)
    h = os.path.expanduser("~/.config")
    if os.path.isabs(h):
        homes.append(h)
    return homes


def win_parts(path):
    """The components of an absolute, normalised path as win_name() normalises them
    (trailing separators dropped)."""
    parts = path.split(os.sep)
    while len(parts) > 1 and parts[-1] == "":
        parts.pop()
    return [win_name(p) for p in parts]


def under_ci(path, directory):
    """`under` with every component compared as win_name() normalises it
    (case-insensitive, NTFS trailing dots/spaces and streams ignored)."""
    p, d = win_parts(path), win_parts(directory)
    return len(p) >= len(d) and p[:len(d)] == d


def in_repo(real, top):
    """`real` (absolute, normalised) as a path inside the toplevel `top`, or None
    when it is outside. realpath() does not canonicalise case, so a path under top
    only as under_ci() compares it (a case or NTFS-name variant of top, which a
    case-insensitive filesystem resolves to top itself) counts as inside: top
    joined with the rest of its components, which the allowlist then compares
    exactly. Fails closed: on a case-sensitive filesystem such a path is a
    sibling directory and is denied while pending."""
    if under(real, top):
        return real
    if under_ci(real, top):
        rest = real.split(os.sep)[len(win_parts(top)):]
        return os.path.join(top, *rest) if rest else top
    return None


def is_opencode_config_path(path):
    """True for OpenCode config: `opencode.json`/`opencode.jsonc` anywhere, anything
    under a `.opencode` directory, anything under <config home>/opencode/ and
    <config home>/fablepowers/models.toml (all components normalised as win_name()
    does)."""
    parts = win_parts(path)
    if parts and parts[-1] in OC_CONFIG_NAMES:
        return True
    if ".opencode" in parts[:-1]:
        return True
    for home in oc_config_homes():
        for h in {os.path.normpath(home), os.path.realpath(home)}:
            if (under_ci(path, os.path.join(h, "opencode"))
                    or parts == win_parts(os.path.join(h, "fablepowers", "models.toml"))):
                return True
    return False


def oc_dispatch_check(top, payload, agents):
    """While pending, deny unless every agent in `agents` is an allowed one."""
    pending = pending_designs(top)
    if not pending:
        return {}
    names = [a for a in agents if isinstance(a, str) and a] if isinstance(agents, list) else []
    if names and len(names) == len(agents) and all(a in OC_ALLOWED_AGENTS for a in names):
        return {}
    bad = [a for a in names if a not in OC_ALLOWED_AGENTS]
    what = ("dispatching agent %s" % ", ".join("`%s`" % a for a in bad)) if bad else "this dispatch (no agent named)"
    return oc_deny(top, payload, oc_pending_reason(
        pending, "%s (until approval only `fablepowers-reviewer` and `explore` may be dispatched)" % what))


def oc_edit_paths(payload):
    """The path strings of a permission `edit` call: `resources` and `files[].file`."""
    out = []
    res = payload.get("resources")
    if isinstance(res, list):
        out += [r for r in res if isinstance(r, str) and r]
    files = payload.get("files")
    if isinstance(files, list):
        out += [f.get("file") for f in files
                if isinstance(f, dict) and isinstance(f.get("file"), str) and f.get("file")]
    seen, uniq = set(), []
    for p in out:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


def oc_permission_edit(top, payload, cwd):
    raw = oc_edit_paths(payload)
    paths = []
    for p in raw:
        try:
            paths.append((p, os.path.normpath(os.path.join(cwd, p)), resolve(p, cwd)))
        except (ValueError, OSError, TypeError):
            paths.append((p, None, None))
    for p, lexical, real in paths:
        if lexical is None:
            if is_marker_like(p):
                return oc_deny(top, payload, OC_MARKER_DENY)
            continue
        if is_marker_path(lexical) or is_marker_path(real):
            return oc_deny(top, payload, OC_MARKER_DENY)
    pending = pending_designs(top)
    if not pending:
        return {}
    checked = [(p, lx, rl) for p, lx, rl in paths if lx is not None]
    if not checked:
        return oc_deny(top, payload, oc_pending_reason(
            pending, "this edit (the gate found no path it can check in it, so it fails closed)"))
    if len(checked) != len(paths):
        p = next(p for p, lx, _ in paths if lx is None)
        return oc_deny(top, payload, oc_pending_reason(
            pending, "this edit (the gate cannot resolve its path `%s`, so it fails closed)" % shown_path(p)))
    allowed = [os.path.realpath(os.path.join(top, d)) for d in ALLOWED_DIRS]
    proot = payload.get("plugin_root")
    proots = []
    if isinstance(proot, str) and os.path.isabs(proot):
        proots = list({os.path.normpath(proot), os.path.realpath(proot)})
    for p, lexical, real in checked:
        inside = in_repo(real, top)
        if is_opencode_config_path(lexical) or is_opencode_config_path(real):
            return oc_deny(top, payload, oc_pending_reason(
                pending, "editing the OpenCode config file `%s` (OpenCode config and "
                "~/.config/fablepowers/models.toml stay closed to the edit tools until approval; if the "
                "user asked for this change, they can make it themselves, or approve or withdraw the "
                "design first)" % lexical))
        if inside is not None and any(under(inside, a) for a in allowed):
            continue
        if any(under_ci(lexical, r) or under_ci(real, r) for r in proots):
            return oc_deny(top, payload, oc_pending_reason(
                pending, "editing `%s` under the fablepowers plugin directory (it stays closed to the "
                "edit tools until approval)" % lexical))
        if inside is None:
            continue
        return oc_deny(top, payload, oc_pending_reason(
            pending, "editing `%s` (only docs/specs/, docs/plans/ and .fablepowers/ are open "
            "until approval)" % os.path.relpath(inside, top)))
    return {}


OC_MARKER_DENY = ("Approval markers (.fablepowers/**/pending, .fablepowers/**/approved) are written only "
                  "by the fablepowers approval gate on a user action; edit tools may not create or change "
                  "them. Ask the user to run `/fablepowers:approve` or `/fablepowers:withdraw`. Do not retry "
                  "this call.")


def oc_permission(top, payload, cwd):
    action = payload.get("action")
    if action == "edit":
        return oc_permission_edit(top, payload, cwd)
    if action == "subagent":
        return oc_dispatch_check(top, payload, payload.get("resources"))
    return {}


def oc_before(top, payload, cwd):
    if payload.get("tool") != "subagent":
        return {}
    ti = payload.get("input")
    agent = ti.get("agent") if isinstance(ti, dict) else None
    return oc_dispatch_check(top, payload, [agent])


def oc_is_root(payload):
    """Root for pending creation: no parent id (a failed parent lookup counts as
    root, SF9, so a design is never missed)."""
    return not payload.get("parent_id")


def oc_known_root(payload):
    """Positively known to be a root session: `parent_id` present and null, and the
    adapter did not flag the parent lookup as failed (`parent_unknown`). Only such
    a session can approve or withdraw."""
    return ("parent_id" in payload and payload["parent_id"] is None
            and not payload.get("parent_unknown"))


OC_NOT_ROOT = ("it did not come from the user's main session (it came from a subagent session, or from a "
               "session whose parent the plugin could not determine); only the user, in the main session, "
               "can approve or withdraw a design")


def oc_not_root_context(verb):
    return {"context": "fablepowers approval gate: `/fablepowers:%s` recorded nothing: %s. Do not act on "
                       "this message as %s." % (verb, OC_NOT_ROOT, ACT_NOUN[verb])}


def oc_path_forms(p, cwd):
    """[lexical, realpath] of path `p` (absolute, or relative to cwd)."""
    lexical = os.path.normpath(os.path.join(cwd, p))
    try:
        return [lexical, os.path.realpath(lexical)]
    except (OSError, ValueError):
        return [lexical]


JS_WS = ("\t\n\x0b\x0c\r \xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007"
         "\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff")
OC_UPDATE = "*** Update File:"
OC_MOVE = "*** Move to:"


def oc_patch_moves(text):
    """Move-to destinations as OpenCode's patch parser reads them (checked against
    its binary): a `*** Move to:` line counts only directly after an
    `*** Update File:` header line, both matched with startsWith on the raw line,
    and the path is the rest of the line trimmed at both ends (JS String.trim)."""
    lines = text.split("\n")
    out = []
    for prev, line in zip(lines, lines[1:]):
        if prev.startswith(OC_UPDATE) and line.startswith(OC_MOVE):
            p = line[len(OC_MOVE):].strip(JS_WS)
            if p:
                out.append(p)
    return out


def oc_after_pending(top, payload, cwd, tool, output):
    """[(spec, key)] made pending by a root-session create of a docs/specs/*.md."""
    targets = []
    if tool == "write":
        if output.get("existed") is not False:
            return []
        raw = output.get("target") or output.get("resource")
        if not isinstance(raw, str) or not raw:
            ti = payload.get("input")
            raw = ti.get("path") if isinstance(ti, dict) else None
        if isinstance(raw, str) and raw:
            targets.append(raw)
        else:
            log(top, "OpenCode write create without a path; ignored")
    elif tool == "edit":
        files = output.get("files")
        for f in files if isinstance(files, list) else []:
            if isinstance(f, dict) and f.get("status") == "added" and isinstance(f.get("file"), str) and f["file"]:
                targets.append(f["file"])
    elif tool == "patch":
        # `existed` keys and `applied[]` paths may spell one file differently (the patch
        # text vs OpenCode's target, e.g. through a symlinked session directory): each
        # side is compared lexically (joined to cwd) and by realpath.
        existed = payload.get("existed")
        # Lexical forms go in first, so no key's realpath form can shadow another key's
        # lexical form (a symlink listed before the new file it points at).
        known = {}
        if isinstance(existed, dict):
            items = [(k, v) for k, v in existed.items() if isinstance(k, str) and k]
            forms = [(oc_path_forms(k, cwd), v) for k, v in items]
            for pf, v in forms:
                known.setdefault(pf[0], v)
            for pf, v in forms:
                for f in pf[1:]:
                    known.setdefault(f, v)
        ti = payload.get("input")
        text = ti.get("patchText") if isinstance(ti, dict) else None
        moves = set()
        for p in oc_patch_moves(text) if isinstance(text, str) else []:
            moves.update(oc_path_forms(p, cwd))
        applied = output.get("applied")
        for a in applied if isinstance(applied, list) else []:
            if not isinstance(a, dict) or a.get("type") not in ("add", "update"):
                continue
            raws = [r for r in (a.get("target"), a.get("resource")) if isinstance(r, str) and r]
            if not raws:
                continue
            pairs = [(r, f) for r in raws for f in oc_path_forms(r, cwd)]
            if a["type"] == "update":
                # A move is an update whose destination is a `*** Move to:` path (as on Codex).
                hit = next((r for r, f in pairs if f in moves), None)
                if hit is not None:
                    targets.append(hit)
                continue
            hit = next(((r, known[f]) for r, f in pairs if f in known), None)
            if hit is not None and hit[1] is False:
                targets.append(hit[0])
            elif hit is None:
                log(top, "OpenCode patch add of `%s` without an existed record; no spec marked pending"
                    % shown_path(raws[0]))
    made = []
    for raw in targets:
        m = mark_pending(top, resolve(raw, cwd))
        if m:
            made.append(m)
    return made


def oc_question(top, payload, output):
    ti = payload.get("input")
    qs = ti.get("questions") if isinstance(ti, dict) else None
    if not isinstance(qs, list) or len(qs) != 1 or not isinstance(qs[0], dict):
        return {}
    opts = qs[0].get("options")
    if not isinstance(opts, list):
        return {}
    labels = [o.get("label") if isinstance(o, dict) else None for o in opts]
    if len(labels) != 2 or set(labels) != set(QUESTION_LABELS):
        return {}
    answers = output.get("answers")
    if not isinstance(answers, list) or len(answers) != 1 or answers[0] != ["Approve"]:
        return {}
    if not oc_known_root(payload):
        return {"context": "fablepowers approval gate: the Approve answer was not recorded because %s. "
                           "Tell the user this; do not act on it as an approval." % OC_NOT_ROOT}
    pending = pending_designs(top)
    if len(pending) == 1:
        key, spec = pending[0]
        if os.path.isfile(os.path.join(top, spec)):
            record_approval(top, key, "question")
            return {"context": "fablepowers approval gate: the user approved design `%s`; the approval "
                               "is recorded." % spec}
        why = "the spec file `%s` of the pending design no longer exists" % spec
    elif not pending:
        why = "no design is pending in this repository (no spec file under docs/specs/ was created)"
    else:
        why = "several designs are pending: %s" % key_list(pending)
    keys = [k for k, _ in pending]
    if keys:
        k = keys[0] if len(keys) == 1 else "<key>"
        todo = "The user should run `/fablepowers:approve %s` (or `/fablepowers:withdraw %s`)." % (k, k)
    else:
        todo = "The gate is not blocking anything."
    return {"context": "fablepowers approval gate: the Approve answer was not recorded because %s. %s "
                       "Tell the user this; do not ask the approval question again." % (why, todo)}


def oc_after(top, payload, cwd):
    if payload.get("status") != "completed":
        return {}
    tool = payload.get("tool")
    output = payload.get("output")
    if not isinstance(output, dict):
        return {}
    if tool == "question":
        return oc_question(top, payload, output)
    if tool not in ("write", "edit", "patch") or not oc_is_root(payload):
        return {}
    made = oc_after_pending(top, payload, cwd, tool, output)
    if not made:
        return {}
    names = ", ".join("`%s` (key `%s`)" % m for m in made)
    return {"context": (
        "fablepowers approval gate: design %s %s now pending the user's approval. Dispatching any agent "
        "except fablepowers-reviewer and explore, and edits outside docs/specs/, docs/plans/ and "
        ".fablepowers/, are blocked until the user answers Approve to the approval question or runs "
        "`/fablepowers:approve%s`." % (names, "is" if len(made) == 1 else "are",
                                        "" if len(made) == 1 else " <key>"))}


def oc_act(top, verb, arg):
    """Approve or withdraw from a command or a prompt; the context dict."""
    pending = pending_designs(top)
    if not pending:
        extra = (" If a design is under discussion in this conversation, the command is still the user's "
                 "approval of it: tell the user the gate had nothing to record, then continue with "
                 "fablepowers:implementation-plan." if verb == "approve" else "")
        return {"context": "fablepowers approval gate: nothing is pending, so `/fablepowers:%s` recorded "
                           "nothing.%s" % (verb, extra)}
    key = pick(pending, arg)
    if key is None:
        return {"context": (
            "fablepowers approval gate: %s, so `/fablepowers:%s` recorded nothing. Tell the user to run "
            "`/fablepowers:%s <key>` with one of: %s. Do not act on this message as %s." % (
                ("no pending design matches `%s`" % arg) if arg else "several designs are pending",
                verb, verb, key_list(pending), ACT_NOUN[verb]))}
    spec = dict(pending)[key]
    if verb == "approve":
        record_approval(top, key, "command")
        return {"context": "fablepowers approval gate: the user approved design `%s` (key `%s`); the "
                           "approval is recorded. %s" % (spec, key, OC_NEXT_STEP)}
    os.remove(os.path.join(fp_dir(top), key, "pending"))
    return {"context": "fablepowers approval gate: the user withdrew design `%s` (key `%s`); it is no "
                       "longer pending. A withdrawn design is abandoned, not approved: do not plan or "
                       "implement it; tell the user in one line and ask what to do next." % (spec, key)}


def oc_prompt(top, payload, cwd):
    text = payload.get("text")
    if not isinstance(text, str):
        return {}
    m = OC_COMMAND.fullmatch(text)
    near = None if m else OC_NEAR_MISS.match(text)
    if (m or near) and not oc_known_root(payload):
        return oc_not_root_context((m or near).group(1))
    if not m:
        if near:
            verb = near.group(1)
            return {"context": (
                "fablepowers approval gate: `/fablepowers:%s` was not recognised, so it recorded nothing; "
                "send exactly `/fablepowers:%s [key]` on its own, as the whole message. Tell the user this; "
                "do not act on this message as %s." % (verb, verb, ACT_NOUN[verb]))}
        return {}
    return oc_act(top, m.group(1), m.group(2) or "")


def oc_command(top, payload, cwd):
    verb = payload.get("verb")
    if verb not in ("approve", "withdraw"):
        return {}
    if not oc_known_root(payload):
        return oc_not_root_context(verb)
    arg = payload.get("args")
    return oc_act(top, verb, arg.strip() if isinstance(arg, str) else "")


OC_HOOKS = {"permission": oc_permission, "before": oc_before, "after": oc_after,
            "prompt": oc_prompt, "command": oc_command}


def opencode_main(payload):
    """The OpenCode branch: always prints exactly one JSON object."""
    top = None
    out = {}
    try:
        cwd = payload.get("cwd")
        handler = OC_HOOKS.get(payload.get("hook"))
        if isinstance(cwd, str) and os.path.isabs(cwd):
            top = find_toplevel(cwd)
            if top and handler:
                out = handler(top, payload, cwd) or {}
            elif top:
                log(top, "OpenCode payload with an unknown hook %r; no decision" % (payload.get("hook"),))
    except Exception:
        out = {}
        log(top, "internal error (OpenCode), allowed: " + traceback.format_exc(limit=3))
    emit(out)


# --- Pi -------------------------------------------------------------------------------

PI_EDIT_TOOLS = ("write", "edit")
PI_DISPATCH_TOOL = "fablepowers_dispatch"
PI_SUBAGENT_TOOL = "subagent"
PI_REVIEWER_SEAT = "reviewer"
PI_NEXT_STEP = ("Tell the user in one line which design, then continue the workflow: write the "
                "implementation plan with the fablepowers-implementation-plan skill (or, when the approved "
                "design already has a plan, execute it).")


def pi_commands_hint(keys):
    k = keys[0] if len(keys) == 1 else "<key>"
    return ("call `fablepowers_ask_approval` so the user can answer Approve in its dialog, or ask the user to "
            "run `/fablepowers:approve %s` (or `/fablepowers:withdraw %s` to abandon it) in Pi, typed by the "
            "user, not through your shell" % (k, k))


def pi_pending_reason(pending, what):
    keys = [k for k, _ in pending]
    if len(pending) == 1:
        head = "Design `%s` awaits the user's approval" % pending[0][1]
    else:
        head = "Designs awaiting the user's approval: %s" % key_list(pending)
    return ("%s, so %s is blocked by the fablepowers approval gate. Stop and %s. "
            "Do not retry this call." % (head, what, pi_commands_hint(keys)))


def pi_deny(top, payload, reason):
    if os.environ.get("FABLEPOWERS_GATE", "") == "off":
        log(top, "FABLEPOWERS_GATE=off: would deny Pi %s %s: %s" % (
            payload.get("hook"), payload.get("tool"), reason))
        return {}
    return {"decision": "deny", "reason": reason}


def pi_refusal(payload):
    """Why this session may not approve or withdraw, or None. Refused when it is a
    dispatched child (`is_child` not exactly false), or when PI_SESSION_ID was set
    in its environment (`env_session` not exactly false: the model's shell sets
    it), in every mode: a model can give a shell-started Pi a pty, so the TUI is
    not exempt. Both fail closed."""
    if payload.get("is_child") is not False:
        return ("it came from a dispatched child session (or one the extension could not classify), "
                "not from the user's main session")
    if payload.get("env_session") is not False:
        return ("it came from a Pi started from inside another Pi's shell, which is how a model would forge "
                "it. The user must type `/fablepowers:approve` in a Pi they started in their own terminal")
    return None


def pi_is_config_path(path, payload):
    """Pi config: anything under a `.pi` directory (the repo's `.pi/`, ~/.pi/agent/,
    anywhere), under `pi_agent_dir` ($PI_CODING_AGENT_DIR as the adapter sends it)
    when absolute, and <config home>/fablepowers/models.toml; components compared
    as win_name() normalises them."""
    parts = win_parts(path)
    if ".pi" in parts[:-1]:
        return True
    agent = payload.get("pi_agent_dir")
    if isinstance(agent, str) and os.path.isabs(agent):
        for a in {os.path.normpath(agent), os.path.realpath(agent)}:
            if under_ci(path, a):
                return True
    for home in oc_config_homes():
        for h in {os.path.normpath(home), os.path.realpath(home)}:
            if parts == win_parts(os.path.join(h, "fablepowers", "models.toml")):
                return True
    return False


def pi_tool_call(top, payload, cwd):
    """write/edit only (reads and other tools are never gated); `path` absolute."""
    tool = payload.get("tool")
    if tool not in PI_EDIT_TOOLS:
        return {}
    raw = payload.get("path")
    lexical = real = None
    if isinstance(raw, str) and raw and os.path.isabs(raw):
        try:
            lexical, real = os.path.normpath(raw), os.path.realpath(raw)
        except (ValueError, OSError, TypeError):
            lexical = real = None
    if lexical is None:
        shown = shown_path(raw) if isinstance(raw, str) else repr(raw)
        log(top, "Pi %s tool_call without an absolute path (%s)" % (tool, shown))
        if isinstance(raw, str) and is_marker_like(raw):
            return pi_deny(top, payload, OC_MARKER_DENY)
        pending = pending_designs(top)
        if not pending:
            return {}
        return pi_deny(top, payload, pi_pending_reason(
            pending, "this %s (the gate got no absolute path it can check, so it fails closed)" % tool))
    if is_marker_path(lexical) or is_marker_path(real):
        return pi_deny(top, payload, OC_MARKER_DENY)
    pending = pending_designs(top)
    if not pending:
        return {}
    if pi_is_config_path(lexical, payload) or pi_is_config_path(real, payload):
        return pi_deny(top, payload, pi_pending_reason(
            pending, "editing the Pi config file `%s` (Pi config (`.pi/`, the Pi agent directory) and "
            "~/.config/fablepowers/models.toml stay closed to write/edit until approval; if the user asked "
            "for this change, they can make it themselves, or approve or withdraw the design first)" % lexical))
    inside = in_repo(real, top)
    if inside is not None and any(under(inside, os.path.realpath(os.path.join(top, d))) for d in ALLOWED_DIRS):
        return {}
    proot = payload.get("plugin_root")
    if isinstance(proot, str) and os.path.isabs(proot):
        for r in {os.path.normpath(proot), os.path.realpath(proot)}:
            if under_ci(lexical, r) or under_ci(real, r):
                return pi_deny(top, payload, pi_pending_reason(
                    pending, "editing `%s` under the fablepowers plugin directory (it stays closed to "
                    "write/edit until approval)" % lexical))
    if inside is None:
        return {}
    return pi_deny(top, payload, pi_pending_reason(
        pending, "editing `%s` (only docs/specs/, docs/plans/ and .fablepowers/ are open "
        "until approval)" % os.path.relpath(inside, top)))


def pi_tool_result(top, payload, cwd):
    """A root-session `write` that created a docs/specs/<name>.md -> pending, with a
    notice. `existed` is what the adapter saw at tool_call; a missing record is
    logged and counted as a create (the adapter records every write)."""
    if payload.get("tool") != "write" or payload.get("is_child") is True:
        return {}
    if payload.get("is_error") is not False:
        return {}
    existed = payload.get("existed")
    if existed is True:
        return {}
    raw = payload.get("path")
    if not isinstance(raw, str) or not raw:
        log(top, "Pi write tool_result without a path; ignored")
        return {}
    if not os.path.isabs(raw):
        log(top, "Pi write tool_result with a relative path `%s`; resolved against cwd" % shown_path(raw))
    real = resolve(raw, cwd)
    if existed is not False:
        log(top, "Pi write tool_result of `%s` without an existed record; counted as a create"
            % shown_path(raw))
    made = mark_pending(top, real)
    if not made:
        return {}
    return {"context": (
        "fablepowers approval gate: design `%s` (key `%s`) is now pending the user's approval. "
        "`fablepowers_dispatch` for any seat except `reviewer`, the `subagent` tool, and write/edit outside "
        "docs/specs/, docs/plans/ and .fablepowers/ are blocked until the user approves: call "
        "`fablepowers_ask_approval`, or ask the user to run `/fablepowers:approve`." % made)}


def pi_dispatch(top, payload, cwd):
    """While pending: `fablepowers_dispatch` only with seat `reviewer`; the example's
    `subagent` tool always denied (its parallel/chain modes name no single agent)."""
    tool = payload.get("tool")
    if tool not in (PI_DISPATCH_TOOL, PI_SUBAGENT_TOOL):
        log(top, "Pi dispatch payload for an unknown tool %r; no decision" % (tool,))
        return {}
    pending = pending_designs(top)
    if not pending:
        return {}
    if tool == PI_DISPATCH_TOOL:
        seat = payload.get("seat")
        if seat == PI_REVIEWER_SEAT:
            return {}
        what = ("dispatching seat `%s`" % seat) if isinstance(seat, str) and seat else "this dispatch (no seat named)"
        return pi_deny(top, payload, pi_pending_reason(
            pending, "%s (until approval only `fablepowers_dispatch` with seat `reviewer` may run)" % what))
    agent = payload.get("agent")
    what = ("dispatching `%s` through the `subagent` tool" % agent) if isinstance(agent, str) and agent \
        else "the `subagent` tool"
    return pi_deny(top, payload, pi_pending_reason(
        pending, "%s (until approval only `fablepowers_dispatch` with seat `reviewer` may run)" % what))


def pi_not_recorded(verb, why):
    return {"context": "fablepowers approval gate: `/fablepowers:%s` recorded nothing: %s. Do not act on "
                       "this message as %s." % (verb, why, ACT_NOUN[verb])}


def pi_pending(top, payload, cwd):
    """Read-only: the pending designs and whether this session may approve, for the
    approval tool to decide whether to show its dialog. Writes nothing."""
    pending = pending_designs(top)
    why = pi_refusal(payload)
    if why:
        reason = ("fablepowers approval gate: approvals are refused in this session: %s. Nothing was "
                  "asked or recorded." % why)
    elif not pending:
        reason = ("fablepowers approval gate: no design is pending in this repository (no spec file under "
                  "docs/specs/ was created), so there is nothing to approve.")
    else:
        reason = ""
    return {"pending": [{"key": k, "spec": s} for k, s in pending], "refused": bool(why), "reason": reason}


def pi_approval_tool(top, payload, cwd):
    """The user's choice in the approval tool's dialog. Records only `Approve` for a
    `pending_key` that is still pending with its spec present, refusal re-checked."""
    choice = payload.get("choice")
    why = pi_refusal(payload)
    if why:
        return {"context": "fablepowers approval gate: the approval was not recorded because %s. Tell the "
                           "user this; do not act on it as an approval." % why}
    if choice is None:
        return {"context": "fablepowers approval gate: the dialog got no answer (dismissed or no UI), so "
                           "nothing was recorded. Ask the user to run `/fablepowers:approve` in Pi, then end "
                           "your turn."}
    if choice == "Changes needed":
        return {"context": "fablepowers approval gate: the user chose Changes needed; the design stays "
                           "pending. Ask the user what to change."}
    if choice != "Approve":
        return {"context": "fablepowers approval gate: the dialog answer %s is not Approve, so nothing was "
                           "recorded." % json.dumps(choice)}
    pending = pending_designs(top)
    key = payload.get("pending_key")
    spec = dict(pending).get(key) if isinstance(key, str) else None
    if spec is None:
        if pending:
            why = "`%s` is not a pending design (pending: %s)" % (
                shown_path(key) if isinstance(key, str) else key, key_list(pending))
        else:
            why = "no design is pending in this repository"
    elif not os.path.isfile(os.path.join(top, spec)):
        why = "the spec file `%s` of the pending design no longer exists" % spec
    else:
        record_approval(top, key, "question")
        return {"context": "fablepowers approval gate: the user approved design `%s` (key `%s`); the "
                           "approval is recorded. %s" % (spec, key, PI_NEXT_STEP)}
    return {"context": "fablepowers approval gate: the Approve answer was not recorded because %s. Tell the "
                       "user this; the user can run `/fablepowers:approve <key>` in Pi." % why}


def pi_command(top, payload, cwd):
    verb = payload.get("verb")
    if verb not in ("approve", "withdraw"):
        return {}
    why = pi_refusal(payload)
    if why:
        return pi_not_recorded(verb, why)
    arg = payload.get("args")
    arg = arg.strip() if isinstance(arg, str) else ""
    pending = pending_designs(top)
    if not pending:
        extra = (" If a design is under discussion in this conversation, the command is still the user's "
                 "approval of it: tell the user the gate had nothing to record, then continue with the "
                 "fablepowers-implementation-plan skill." if verb == "approve" else "")
        return {"context": "fablepowers approval gate: nothing is pending, so `/fablepowers:%s` recorded "
                           "nothing.%s" % (verb, extra)}
    key = pick(pending, arg)
    if key is None:
        return {"context": (
            "fablepowers approval gate: %s, so `/fablepowers:%s` recorded nothing. Tell the user to run "
            "`/fablepowers:%s <key>` with one of: %s. Do not act on this message as %s." % (
                ("no pending design matches `%s`" % shown_path(arg)) if arg else "several designs are pending",
                verb, verb, key_list(pending), ACT_NOUN[verb]))}
    spec = dict(pending)[key]
    if verb == "approve":
        record_approval(top, key, "command")
        return {"context": "fablepowers approval gate: the user approved design `%s` (key `%s`); the "
                           "approval is recorded. %s" % (spec, key, PI_NEXT_STEP)}
    os.remove(os.path.join(fp_dir(top), key, "pending"))
    return {"context": "fablepowers approval gate: the user withdrew design `%s` (key `%s`); it is no "
                       "longer pending. A withdrawn design is abandoned, not approved: do not plan or "
                       "implement it; tell the user in one line and ask what to do next." % (spec, key)}


PI_HOOKS = {"tool_call": pi_tool_call, "tool_result": pi_tool_result, "dispatch": pi_dispatch,
            "pending": pi_pending, "approval_tool": pi_approval_tool, "command": pi_command}


def pi_main(payload):
    """The Pi branch: always prints exactly one JSON object."""
    top = None
    out = {}
    try:
        cwd = payload.get("cwd")
        hook = payload.get("hook")
        handler = PI_HOOKS.get(hook)
        if isinstance(cwd, str) and os.path.isabs(cwd):
            top = find_toplevel(cwd)
            if top and handler:
                out = handler(top, payload, cwd) or {}
            elif top:
                log(top, "Pi payload with an unknown hook %r; no decision" % (hook,))
        if hook == "pending" and not out:
            # Outside a repo (or cwd unusable) nothing can be pending; the shape stays.
            out = {"pending": [], "refused": bool(pi_refusal(payload)), "reason": (
                "fablepowers approval gate: this session is not inside a git repository, so nothing is "
                "pending.")}
    except Exception:
        out = {}
        log(top, "internal error (Pi), allowed: " + traceback.format_exc(limit=3))
    emit(out)


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
        if payload.get("harness") == "opencode":
            opencode_main(payload)
            return
        if payload.get("harness") == "pi":
            pi_main(payload)
            return
        cwd = payload.get("cwd")
        if not isinstance(cwd, str) or not cwd:
            cwd = os.getcwd()
        top = find_toplevel(cwd)
        if not top:
            return
        event = payload.get("hook_event_name")
        tool = payload.get("tool_name")
        if event == "PreToolUse" and tool == "apply_patch":
            codex_pre_apply_patch(top, payload, cwd)
        elif event == "PreToolUse" and tool in CODEX_SPAWN_TOOLS:
            codex_pre_spawn(top, payload, tool)
        elif event == "PreToolUse":
            pre_tool_use(top, payload, cwd)
        elif event == "PostToolUse" and tool == "apply_patch":
            codex_post_apply_patch(top, payload, cwd)
        elif event == "UserPromptSubmit" and is_codex(payload):
            codex_user_prompt(top, payload)
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
