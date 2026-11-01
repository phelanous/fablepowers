#!/usr/bin/env python3
"""Per-session delegation analysis for Claude Code, Codex, OpenCode and Pi session logs.

Answers one question: when you ran this workflow, who actually did the work --
the orchestrator in the main loop, or the subagents it dispatched?

Claude Code writes one JSONL transcript per session under `~/.claude/projects`
(read by default; override with --projects-dir), plus one
`<session>/subagents/agent-*.jsonl` per dispatched subagent. Naive log counters
treat those subagent files as sessions of their own. This script pairs each main
transcript with its subagent transcripts and reports, per session:

  * main-loop vs subagent output tokens (who is doing the work)
  * who edits files: main-loop Edit/Write + Bash heredoc writes vs subagent edits
  * which model each subagent actually ran on (from the assistant records)
  * the `model` param passed on Agent spawns (unset => inherits the main model)
  * skills invoked, and whether design-spec's approval checkpoint got a user turn
  * a rough $ estimate per session (see PRICE below)

Each harness has a reader that yields the same session record (see
`read_claude`); one printer shows them. `--harness claude` prints exactly the
Claude-only report this script printed before it read other harnesses, so
earlier audits stay reproducible. Any other selection (the default is `all`)
prints one date-sorted table with a harness column (cc, cx, oc, pi), then one
summary line per harness and an `all` line. A harness with no logs on this
machine is skipped with a note.

Usage:
    python3 scripts/analyze_delegation.py [--harness all|claude,codex,opencode,pi]
        [--since YYYY-MM-DD] [--projects-dir DIR] [--codex-home DIR]
        [--opencode-db FILE] [--pi-sessions DIR]

Stdlib only.
"""
import argparse, collections, datetime, glob, json, math, os, re, sqlite3, urllib.parse

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
# $/MTok: input, cache_write, cache_read, output.
# Snapshot of public list prices as of June 2026 -- update it before trusting the
# dollar columns. The fable-5 cache-read rate is an assumption, not a published
# number; every other row comes from the published table.
PRICE = {
    "claude-fable-5-1": (10, 12.5, 0.25, 50), "claude-fable-5": (10, 12.5, 1.0, 50),
    "claude-opus-5": (5, 6.25, 0.5, 25), "claude-opus-4-8": (5, 6.25, 0.5, 25),
    "claude-sonnet-5": (2, 2.5, 0.2, 10), "claude-haiku-4-5-20251001": (1, 1.25, 0.1, 5),
}
WRITE_RE = re.compile(r"cat\s*>|<<\s*'?EOF|sed\s+-i|tee\s|>\s*\S+\.(py|ts|tsx|js|dart|md|json|ya?ml|toml|sh|css|html)")


def recs(path):
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def cost(usage, model):
    p = PRICE.get(model)
    if not p:
        return 0.0
    return (usage.get("input_tokens", 0) * p[0] + usage.get("cache_creation_input_tokens", 0) * p[1]
            + usage.get("cache_read_input_tokens", 0) * p[2] + usage.get("output_tokens", 0) * p[3]) / 1e6


AGENT_ROLES = {"fablepowers:reviewer": "reviewer",
               "fablepowers:implementer": "implementer",
               "fablepowers:strict-implementer": "implementer"}


def role(prompt, desc="", subagent_type=None):
    """A fablepowers agent's `subagent_type` names its role outright. Anything else
    falls back to a prompt-text heuristic, which over-counts reviewers: fix-round
    dispatches to an implementer mention "review"."""
    if subagent_type in AGENT_ROLES:
        return AGENT_ROLES[subagent_type]
    p = (desc + " " + prompt[:600]).lower()
    if re.search(r"review|critique|audit|verify|spec.?check|adversarial", p):
        return "reviewer"
    if re.search(r"implement|write the code|fix the|apply|refactor|task \d|build", p):
        return "implementer"
    if re.search(r"explore|search|find|locate|map|research|investigate|analy", p):
        return "explorer"
    return "other"


def bare_skill(name):
    """`fablepowers:design-spec` -> `design-spec`; leaves unnamespaced names alone."""
    return (name or "").rsplit(":", 1)[-1]


def short_project(dirname, width=34):
    """Claude Code names a project directory after its path with the separators
    replaced by dashes. Keep the tail -- that is the part that names the project."""
    name = dirname.lstrip("-").replace("--claude-worktrees-", "/")
    return name if len(name) <= width else ".." + name[-(width - 2):]


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def scan_main(path):
    s = dict(ts=None, models=collections.Counter(), out=0, cost=0.0, skills=[], spawns=[],
             edits=0, bash_writes=0, user_turns=0, seq=[])
    for o in recs(path):
        if s["ts"] is None and o.get("timestamp"):
            s["ts"] = o["timestamp"][:10]
        m = o.get("message") or {}
        c = m.get("content")
        if o.get("type") == "user" and not o.get("isMeta"):
            t = text_of(c)
            if t.strip() and not (isinstance(c, list) and any(b.get("type") == "tool_result" for b in c if isinstance(b, dict))):
                s["user_turns"] += 1
                s["seq"].append(("user", t[:60]))
        if o.get("type") != "assistant":
            continue
        u = m.get("usage") or {}
        s["out"] += u.get("output_tokens", 0)
        s["cost"] += cost(u, m.get("model"))
        if m.get("model"):
            s["models"][m["model"]] += 1
        if not isinstance(c, list):
            continue
        for b in c:
            if b.get("type") != "tool_use":
                continue
            n, i = b.get("name"), b.get("input") or {}
            if n == "Skill":
                s["skills"].append(i.get("skill", "?")); s["seq"].append(("skill", bare_skill(i.get("skill"))))
            elif n in EDIT_TOOLS:
                s["edits"] += 1; s["seq"].append(("edit", i.get("file_path", "")))
            elif n == "Bash" and WRITE_RE.search(i.get("command", "")):
                s["bash_writes"] += 1; s["seq"].append(("edit", "bash-write"))
            elif n == "AskUserQuestion":
                s["seq"].append(("ask", ""))
            elif n in ("Agent", "Task"):
                s["spawns"].append(dict(model=i.get("model"), role=role(i.get("prompt", ""), i.get("description", ""), i.get("subagent_type"))))
    return s


def scan_subs(session_dir):
    subs = []
    for sub in glob.glob(os.path.join(session_dir, "subagents", "agent-*.jsonl")):
        ss = dict(models=collections.Counter(), out=0, cost=0.0, edits=0)
        for o in recs(sub):
            if o.get("type") != "assistant":
                continue
            m = o.get("message") or {}; u = m.get("usage") or {}
            ss["out"] += u.get("output_tokens", 0); ss["cost"] += cost(u, m.get("model"))
            if m.get("model"):
                ss["models"][m["model"]] += 1
            for b in (m.get("content") or []):
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") in EDIT_TOOLS:
                    ss["edits"] += 1
        subs.append(ss)
    return subs


def approval_gap(seq):
    """User turns between design-spec and the first implementation action (None if no design-spec).
    An `approved` event (a Pi approval-command result) counts as a user turn: on Claude
    and OpenCode the same `/fablepowers:approve` is a user message. Claude never emits it."""
    try:
        i0 = next(i for i, (k, v) in enumerate(seq) if k == "skill" and v == "design-spec")
    except StopIteration:
        return None
    after = seq[i0:]
    stop = next((i for i, (k, v) in enumerate(after)
                 if (k == "skill" and v == "implementation-plan") or (k == "edit" and not re.search(r"specs?/|plans?/|\.md$", v))), len(after))
    return sum(1 for k, _ in after[:stop] if k in ("user", "approved"))


# --harness names -> the short code in the record's `harness` field and the `h` column.
HARNESSES = {"claude": "cc", "codex": "cx", "opencode": "oc", "pi": "pi"}


def read_claude(a):
    """Claude Code reader: one record per main transcript, in sorted path order.

    A record is a dict: harness, ts (YYYY-MM-DD), proj, models (Counter of
    main-loop model ids), user_turns, out, cost (float, or None where the harness
    records no price), skills, spawns ([{role, model}]), edits, bash_writes,
    seq (approval-gap events) and subs ([{models, out, cost, edits}]).
    Every reader returns (records, note) -- note is None or one line for the summary."""
    if not os.path.isdir(a.projects_dir):
        return [], f"no claude logs at {a.projects_dir}"
    rows = []
    for main in sorted(glob.glob(os.path.join(a.projects_dir, "*", "*.jsonl"))):
        if "/memory/" in main:
            continue
        s = scan_main(main)
        if not s["ts"] or (a.since and s["ts"] < a.since):
            continue
        s["harness"] = "cc"
        s["proj"] = short_project(os.path.basename(os.path.dirname(main)))
        s["subs"] = scan_subs(os.path.join(os.path.dirname(main), os.path.basename(main)[:-6]))
        rows.append(s)
    return rows, None


def path_project(cwd, width=34):
    """A session's working directory -> project name: the basename, or
    `<repo>/<worktree>` for a Claude worktree (as `short_project` renders it)."""
    parts = (cwd or "").rstrip("/").split("/")
    name = parts[-1] if parts and parts[-1] else "?"
    if len(parts) >= 4 and parts[-3:-1] == [".claude", "worktrees"]:
        name = parts[-4] + "/" + name
    return name if len(name) <= width else ".." + name[-(width - 2):]


SEAT_ROLES = (("reviewer", "reviewer"), ("implementer", "implementer"))  # strict_implementer contains implementer


def seat_role(name):
    """A fablepowers seat or task name (`fp-reviewer`, `Fablepowers.Reviewer-T0`,
    `fablepowers_strict_implementer_t2`) -> its role, or None."""
    n = re.sub(r"[.\-\s]", "_", (name or "").lower())
    return next((r for k, r in SEAT_ROLES if k in n), None)


FP_AGENT = re.compile(r"(fp|fablepowers)[-_:]")  # fablepowers agent types: fp-implementer, fablepowers-reviewer
SEAT_LINE = re.compile(r"^\s*fablepowers-seat:\s*([A-Za-z0-9_.-]+)")
ROLE_FILE = re.compile(r"(?:agents|roles)/(?:fp-|fablepowers-)?(strict-implementer|implementer|reviewer)\.(?:md|toml)")
SKILL_READ = re.compile(r"\S*?skills/([A-Za-z0-9_-]+)/SKILL\.md")
READ_VERBS = {"cat", "sed", "head", "tail", "nl", "less", "more", "bat"}
CX_SELECTED = re.compile(r"<skill>\s*<name>([^<\s]+)</name>")
PATCH_FILE = re.compile(r"\*\*\* (?:Add|Update|Delete) File: ([^\n\\\"']+)")
JS_CALL = re.compile(r"tools\.([A-Za-z0-9_]+)\(")
JS_MODEL = re.compile(r"model\s*:\s*[\"']([^\"']+)[\"']")


def text_role(text):
    """A dispatch prompt's role: its `fablepowers-seat:` first line, a role-file
    reference, else the prompt-text heuristic."""
    m = SEAT_LINE.match(text or "")
    r = seat_role(m.group(1)) if m else None
    if r is None:
        m = ROLE_FILE.search(text or "")
        r = seat_role(m.group(1)) if m else None
    return r or role(text or "")


def cx_skill_reads(cmd):
    """SKILL.md files a shell command reads (cat/sed/head/... -- not ls/rg/find)."""
    out = []
    for seg in re.split(r"&&|\|\||;|\||\n", cmd or ""):
        words = seg.split()
        if not words or os.path.basename(words[0]) not in READ_VERBS:
            continue
        for m in SKILL_READ.finditer(seg):
            out.append(("fablepowers:" if "fablepowers" in m.group(0) else "") + m.group(1))
    return out


def cx_meta(path):
    """The rollout's first record (session_meta) -> its payload, or None."""
    try:
        with open(path, errors="replace") as fh:
            o = json.loads(fh.readline())
    except (OSError, ValueError):
        return None
    return o.get("payload") if isinstance(o, dict) and o.get("type") == "session_meta" else None


def spawn_info(meta):
    """session_meta.source.subagent.thread_spawn, or {}."""
    src = meta.get("source")
    sub_ = src.get("subagent") if isinstance(src, dict) else None
    return (sub_.get("thread_spawn") if isinstance(sub_, dict) else None) or {}


def cx_parent(meta):
    """Parent thread id of a spawned child; None for a root; False for a subagent
    rollout that was not spawned by a thread (review, compact)."""
    src = meta.get("source")
    if not isinstance(src, dict) or "subagent" not in src:
        return None
    return spawn_info(meta).get("parent_thread_id") or False


def scan_codex(path):
    """One rollout, streamed. Edits and spawns count attempts (calls made), with
    FileChange / CollabAgentToolCall items supplying the files and models of the
    calls that ran; output = the last thread_token_usage (survives compaction)."""
    s = dict(models=collections.Counter(), out=0, user_turns=0, skills=[], edits=0, bash_writes=0, seq=[],
             spawns=[], first_user=None)
    thread_out = usage_sum = tc_total = None
    win = None  # the open tool call: attempted patches/spawns not yet matched by an item

    def close():
        nonlocal win
        if win:
            for p in win["patches"]:
                s["edits"] += 1; s["seq"].append(("edit", p))
            for m in win["spawns"]:
                s["spawns"].append(dict(m, child=None))
        win = None

    for o in recs(path):
        t, p = o.get("type"), o.get("payload") or {}
        if t == "turn_context":
            if p.get("model"):
                s["models"][p["model"]] += 1
        elif t == "token_usage_record":
            u = (p.get("usage") or {}).get("output_tokens") or 0
            usage_sum = (usage_sum or 0) + u
            if (p.get("thread_token_usage") or {}).get("output_tokens") is not None:
                thread_out = p["thread_token_usage"]["output_tokens"]
        elif t == "event_msg" and p.get("type") == "token_count" and p.get("info"):
            tc_total = ((p["info"].get("total_token_usage") or {}).get("output_tokens"))
        elif t == "response_item" and p.get("type") in ("custom_tool_call", "function_call"):
            close()
            name, win = p.get("name") or "", dict(id=p.get("call_id"), patches=[], spawns=[])
            if p.get("type") == "custom_tool_call":
                body = p.get("input") or ""
                if name == "apply_patch":
                    win["patches"] = [(PATCH_FILE.findall(body) or [""])[0]]
                calls = list(JS_CALL.finditer(body))
                for m, nxt in zip(calls, calls[1:] + [None]):
                    js = body[m.end():nxt.start() if nxt else len(body)]  # this call's arguments, roughly
                    if m.group(1) == "apply_patch":
                        win["patches"].append((PATCH_FILE.findall(js) or [""])[0])
                    elif m.group(1).endswith("spawn_agent"):
                        mm = JS_MODEL.search(js)
                        seat = re.search(r"fablepowers-seat:\s*([A-Za-z0-9_.-]+)", js)
                        win["spawns"].append(dict(model=mm.group(1) if mm else None,
                                                  role=seat_role(seat.group(1)) if seat else None, msg=js))
                    elif m.group(1) == "request_user_input":
                        s["seq"].append(("ask", ""))
            else:
                try:
                    args = json.loads(p.get("arguments") or "{}")
                except ValueError:
                    args = {}
                args = args if isinstance(args, dict) else {}
                if name in ("spawn_agent", "collaborationspawn_agent", "multi_agent_v1__spawn_agent"):
                    at, task = args.get("agent_type") or "", args.get("task_name") or ""
                    seat = seat_role(at) if FP_AGENT.match(at) else None
                    r = seat or seat_role(task)
                    # A fablepowers agent type pins its model in its config, like a seat elsewhere.
                    win["spawns"].append(dict(model=args.get("model") or ("seat" if seat else None), role=r, task=task,
                                              msg=args.get("message") or args.get("prompt") or ""))
                elif name == "apply_patch":
                    win["patches"].append((PATCH_FILE.findall(args.get("input") or "") or [""])[0])
            if name == "request_user_input":
                s["seq"].append(("ask", ""))
        elif t == "response_item" and p.get("type") in ("custom_tool_call_output", "function_call_output"):
            if win and win["id"] == p.get("call_id"):
                close()
        elif t == "response_item" and p.get("type") == "message" and p.get("role") == "user":
            kinds = (p.get("internal_chat_message_metadata_passthrough") or {}).get("content_item_kinds") or []
            if "skills.selected_skill_instructions" in kinds:
                for x in p.get("content") or []:
                    for n in CX_SELECTED.findall(x.get("text") or "" if isinstance(x, dict) else ""):
                        s["skills"].append(n); s["seq"].append(("skill", bare_skill(n)))
        elif t == "event_msg" and p.get("type") == "item_completed":
            it = p.get("item") or {}
            k = it.get("type")
            if k == "UserMessage":
                tx = " ".join(x.get("text") or "" for x in it.get("content") or [] if isinstance(x, dict))
                s["user_turns"] += 1; s["seq"].append(("user", tx[:60]))
                if s["first_user"] is None:
                    s["first_user"] = tx
            elif k == "FileChange":
                if win and win["patches"]:
                    win["patches"].pop(0)
                for f in it.get("changes") or {}:
                    s["edits"] += 1; s["seq"].append(("edit", f))
            elif k == "CommandExecution":
                cmd = it.get("command")
                cmd = cmd[-1] if isinstance(cmd, list) and cmd else cmd if isinstance(cmd, str) else ""
                for n in cx_skill_reads(cmd):
                    s["skills"].append(n); s["seq"].append(("skill", bare_skill(n)))
                if WRITE_RE.search(cmd):
                    s["bash_writes"] += 1; s["seq"].append(("edit", "bash-write"))
            elif k == "CollabAgentToolCall" and it.get("tool") == "spawn_agent":
                att = win["spawns"].pop(0) if win and win["spawns"] else {}
                s["spawns"].append(dict(att, model=it.get("model") or att.get("model"), role=att.get("role"),
                                        child=(it.get("receiver_thread_ids") or [None])[0],
                                        prompt=it.get("prompt") or ""))
    close()
    s["out"] = thread_out if thread_out is not None else usage_sum if usage_sum is not None else (tc_total or 0)
    return s


def read_codex(a):
    """Codex reader: one record per root rollout under <codex home>/sessions.

    Children (spawned threads, any depth) are rolled up into their root's subs;
    children whose root is missing go to one `(orphan)` record per missing
    parent. Cost is None (Codex logs no price). `.jsonl.zst` rollouts are skipped
    with a note."""
    base = os.path.join(a.codex_home, "sessions")
    if not os.path.isdir(base):
        return [], f"no codex logs at {base}"
    files, zst = [], 0
    for d, _, names in os.walk(base):
        for n in names:
            if n.endswith(".jsonl"):
                files.append(os.path.join(d, n))
            elif n.endswith(".jsonl.zst"):
                zst += 1
    meta, other, unknown = {}, 0, 0
    for f in sorted(files):
        m = cx_meta(f)
        if not m or not m.get("id"):
            unknown += 1
            continue
        par = cx_parent(m)
        if par is False:
            other += 1
            continue
        meta[m["id"]] = (f, m, par)

    def root_of(tid):
        seen = set()
        while meta[tid][2] is not None:
            if meta[tid][2] not in meta or tid in seen:
                return None, meta[tid][2]
            seen.add(tid); tid = meta[tid][2]
        return tid, None

    groups = collections.defaultdict(list)  # root id or ("orphan", missing parent) -> child ids
    for tid, (_, _, par) in meta.items():
        if par is not None:
            r, missing = root_of(tid)
            groups[r if r else ("orphan", missing)].append(tid)
    date = lambda m: (m.get("timestamp") or "")[:10]
    rows = []

    def subs_of(kids):
        out, scans = [], {}
        for c in sorted(kids, key=lambda c: meta[c][0]):
            sc = scans[c] = scan_codex(meta[c][0])
            out.append(dict(models=sc["models"], out=sc["out"], cost=None, edits=sc["edits"]))
        return out, scans

    for tid, (f, m, par) in sorted(meta.items(), key=lambda kv: kv[1][0]):
        if par is not None or not date(m) or (a.since and date(m) < a.since):
            continue
        s = scan_codex(f)
        subs, scans = subs_of(groups.get(tid, []))
        # A v2 child names its spawn call's task in agent_path (`/root/<task_name>`).
        by_task = {spawn_info(meta[c][1]).get("agent_path", "").rsplit("/", 1)[-1]: c
                   for c in groups.get(tid, []) if meta[c][2] == tid and spawn_info(meta[c][1]).get("agent_path")}
        for sp in s["spawns"]:
            if sp.get("role") is None:  # no seat in agent_type / task_name / the JS literal
                child = sp.get("child") or by_task.get(sp.get("task"))
                agent_role = spawn_info(meta[child][1]).get("agent_role") or "" if child in meta else ""
                text = (scans[child]["first_user"] if child in scans else None) or sp.get("prompt") or sp.get("msg") or ""
                sp["role"] = (seat_role(agent_role) if FP_AGENT.match(agent_role) else None) or text_role(text)
        rows.append(dict(harness="cx", ts=date(m), proj=path_project(m.get("cwd")), models=s["models"],
                         user_turns=s["user_turns"], out=s["out"], cost=None, skills=s["skills"],
                         spawns=[dict(role=x["role"], model=x["model"]) for x in s["spawns"]], edits=s["edits"],
                         bash_writes=s["bash_writes"], seq=s["seq"], subs=subs))
    for key in sorted((k for k in groups if isinstance(k, tuple)), key=lambda k: min(meta[c][0] for c in groups[k])):
        kids = groups[key]
        first = min(kids, key=lambda c: (meta[c][1].get("timestamp") or "", meta[c][0]))
        ts = date(meta[first][1])
        if not ts or (a.since and ts < a.since):
            continue
        subs, _ = subs_of(kids)
        proj = "(orphan) " + path_project(meta[first][1].get("cwd"))
        rows.append(dict(harness="cx", ts=ts, proj=proj if len(proj) <= 34 else proj[:32] + "..",
                         models=collections.Counter(), user_turns=0, out=0, cost=None, skills=[], spawns=[], edits=0,
                         bash_writes=0, seq=[], subs=subs))
    notes = []
    if zst:
        notes.append(f"{zst} .jsonl.zst rollout(s) skipped (zstd is not in the stdlib)")
    if other:
        notes.append(f"{other} non-spawn subagent rollout(s) skipped")
    if unknown:
        notes.append(f"{unknown} rollout(s) skipped: no session_meta")
    return rows, "; ".join(notes) or None


OC_EDIT_TOOLS = {"edit", "write"}


def oc_open(path):
    """Open the OpenCode db read-only -> (connection, note). `mode=ro` (not
    `immutable`) so rows still in the WAL of a running OpenCode are read; if that
    open fails (no -shm in a read-only dir), fall back to `immutable=1` and say so."""
    uri = "file:" + urllib.parse.quote(os.path.abspath(path))
    try:
        con = sqlite3.connect(uri + "?mode=ro", uri=True)
        con.execute("SELECT name FROM sqlite_master LIMIT 1").fetchall()
        return con, None
    except sqlite3.Error:
        con = sqlite3.connect(uri + "?mode=ro&immutable=1", uri=True)
        return con, f"opened {path} immutable (read-only open failed), so rows still in its WAL are missing"


def oc_json(text):
    try:
        d = json.loads(text)
    except (TypeError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def oc_model(d):
    m = d.get("model")
    return (m.get("id") if isinstance(m, dict) else m) or None


def scan_opencode(con, sid):
    """One session's messages in `seq` order. Out = output + reasoning and cost =
    the recorded cost, both summed over assistant and compaction messages; edits
    and spawns count attempts (every tool call, errored ones too). A `subagent`
    call carrying `input.sessionID` resumes an existing child: not a new spawn."""
    s = dict(models=collections.Counter(), out=0, cost=0.0, user_turns=0, skills=[], edits=0, bash_writes=0,
             seq=[], spawns=[], messages=0)
    costs = []
    for typ, data in con.execute("SELECT type, data FROM session_message WHERE session_id = ? ORDER BY seq", (sid,)):
        s["messages"] += 1
        d = oc_json(data)
        if typ == "user":  # `synthetic` messages (gate notices, reminders) are not user turns
            t = d.get("text") or ""
            s["user_turns"] += 1; s["seq"].append(("user", t[:60]))
            continue
        if typ not in ("assistant", "compaction"):
            continue
        tk = d.get("tokens") or {}
        s["out"] += (tk.get("output") or 0) + (tk.get("reasoning") or 0)
        costs.append(d.get("cost") or 0.0)
        if oc_model(d):
            s["models"][oc_model(d)] += 1
        for b in d.get("content") or []:
            if not isinstance(b, dict) or b.get("type") != "tool":
                continue
            n, st = b.get("name"), b.get("state") or {}
            i = st.get("input") if isinstance(st.get("input"), dict) else {}
            if n == "skill":
                s["skills"].append(i.get("id") or "?"); s["seq"].append(("skill", bare_skill(i.get("id"))))
            elif n in OC_EDIT_TOOLS:
                s["edits"] += 1; s["seq"].append(("edit", i.get("path") or ""))
            elif n == "shell" and WRITE_RE.search(i.get("command") or ""):
                s["bash_writes"] += 1; s["seq"].append(("edit", "bash-write"))
            elif n == "question":
                s["seq"].append(("ask", ""))
            elif n == "subagent" and not i.get("sessionID"):
                agent = i.get("agent") or ""
                seat = agent.startswith("fablepowers-")
                r = (seat_role(agent) if FP_AGENT.match(agent) else None) or role(i.get("prompt") or "", i.get("description") or "")
                s["spawns"].append(dict(role=r, model=i.get("model") or ("seat" if seat else None)))
    s["cost"] = math.fsum(costs)
    return s


def read_opencode(a):
    """OpenCode reader: one record per root session (`session_v2.parent_id` NULL).

    Descendants at any depth roll up into their root's subs; children whose root
    is missing go to one `(orphan)` record per missing parent. Tokens and cost
    come from `session_message`, not the `session_v2` totals (which also count
    side calls such as title generation). A root with no messages and no
    descendants is dropped, as the Claude reader drops a transcript with no timestamp. An SQLite error at any
    point (a locked or corrupt db, an unknown schema) is a note, never a crash."""
    path = a.opencode_db
    if not os.path.isfile(path):
        return [], f"no opencode logs at {path}"
    con = None
    try:
        con, note = oc_open(path)
        return oc_records(con, path, a.since, note)
    except sqlite3.Error as e:
        return [], f"cannot read {path} ({e})"
    finally:
        if con is not None:
            con.close()


def oc_records(con, path, since, note):
    tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    if "session_v2" not in tables or "session_message" not in tables:
        return [], f"no session_v2 table in {path} (not an OpenCode 2.x db)"
    sess = {}
    for sid, par, directory, created in con.execute(
            "SELECT id, parent_id, directory, time_created FROM session_v2 ORDER BY time_created, id"):
        ts = datetime.datetime.fromtimestamp((created or 0) / 1000, datetime.timezone.utc).strftime("%Y-%m-%d")
        sess[sid] = dict(par=par or None, proj=path_project(directory), ts=ts)

    def root_of(sid):
        seen = set()
        while sess[sid]["par"] is not None:
            par = sess[sid]["par"]
            if par not in sess or sid in seen:
                return None, par
            seen.add(sid); sid = par
        return sid, None

    groups = collections.defaultdict(list)  # root id or ("orphan", missing parent) -> descendant ids, in start order
    for sid, x in sess.items():
        if x["par"] is not None:
            r, missing = root_of(sid)
            groups[r if r else ("orphan", missing)].append(sid)

    def subs_of(kids):
        out = []
        for c in kids:
            sc = scan_opencode(con, c)
            out.append(dict(models=sc["models"], out=sc["out"], cost=sc["cost"], edits=sc["edits"]))
        return out

    rows = []
    for sid, x in sess.items():
        if x["par"] is not None or (since and x["ts"] < since):
            continue
        s = scan_opencode(con, sid)
        if not s["messages"] and not groups.get(sid):
            continue
        rows.append(dict(harness="oc", ts=x["ts"], proj=x["proj"], models=s["models"], user_turns=s["user_turns"],
                         out=s["out"], cost=s["cost"], skills=s["skills"], spawns=s["spawns"], edits=s["edits"],
                         bash_writes=s["bash_writes"], seq=s["seq"], subs=subs_of(groups.get(sid, []))))
    for key in (k for k in groups if isinstance(k, tuple)):
        first = sess[groups[key][0]]
        if since and first["ts"] < since:
            continue
        proj = "(orphan) " + first["proj"]
        rows.append(dict(harness="oc", ts=first["ts"], proj=proj if len(proj) <= 34 else proj[:32] + "..",
                         models=collections.Counter(), user_turns=0, out=0, cost=0.0, skills=[], spawns=[], edits=0,
                         bash_writes=0, seq=[], subs=subs_of(groups[key])))
    return rows, note


PI_EDIT_TOOLS = {"edit", "write"}
PI_SKILL_TAG = re.compile(r"<skill\s+name=\"([^\"]+)\"")
PI_APPROVED = re.compile(r"^\s*(?:fablepowers approval gate:\s*)?the user approved design")
PI_KEY = re.compile(r"\(key `([^`]*)`\)")
PI_DESIGN = re.compile(r"design `([^`]*)`")
CHILDREN_DIR = "fablepowers-children"


def pi_skill(name, path=""):
    """A Pi skill name or SKILL.md path segment -> the listed name: the wrapper
    `fablepowers-<x>` becomes `fablepowers:<x>`, a real skill under a fablepowers
    plugin root `fablepowers:<x>`, anything else stays as it is."""
    if name.startswith("fablepowers-"):
        return "fablepowers:" + name[len("fablepowers-"):]
    if ":" not in name and "fablepowers" in path:
        return "fablepowers:" + name
    return name


def pi_header(path):
    """The session file's header (`{"type": "session", "id", "timestamp", "cwd"}`), or None."""
    try:
        with open(path, errors="replace") as fh:
            o = json.loads(fh.readline())
    except (OSError, ValueError):
        return None
    return o if isinstance(o, dict) and o.get("type") == "session" and o.get("id") else None


def pi_spawn(name, args):
    """A dispatch tool call -> {role, model}. `fablepowers_dispatch` names a seat
    (pinned by config: model `seat`); the `subagent` tool of the separate
    pi-subagents extension names an agent and a task (or `tasks`/`chain` lists)."""
    if name == "fablepowers_dispatch":
        seat = args.get("seat") if isinstance(args.get("seat"), str) else ""
        task = args.get("task") if isinstance(args.get("task"), str) else ""
        return dict(role=seat_role(seat) or role(task), model=args.get("model") or "seat")
    first = next((x for k in ("tasks", "chain") if isinstance(args.get(k), list)
                  for x in args[k] if isinstance(x, dict)), args)
    agent = first.get("agent") if isinstance(first.get("agent"), str) else ""
    task = first.get("task") if isinstance(first.get("task"), str) else ""
    return dict(role=seat_role(agent) or role(task), model=args.get("model") or None)


def pi_entry_ids(path):
    """The entry ids in a Pi session file."""
    return {o.get("id") for o in recs(path) if isinstance(o, dict) and o.get("id")} if os.path.isfile(path) else set()


def scan_pi(path, skip=frozenset()):
    """One Pi session file (every entry, abandoned branches included). Out = Σ
    usage.output, cost = Σ usage.cost.total (fsum); edits and spawns count attempts.
    Approval results become `approved` events; `fablepowers-child` entries map
    child session ids to this session. Entries whose id is in `skip` (held by an
    earlier session, e.g. copied into a fork) are not counted."""
    s = dict(models=collections.Counter(), out=0, cost=0.0, user_turns=0, skills=[], edits=0, bash_writes=0,
             seq=[], spawns=[], children=[], messages=0)
    costs = []

    def skill(name):
        if s["seq"][-1:] != [("skill", bare_skill(name))]:  # wrapper read, then the real SKILL.md: one load
            s["skills"].append(name); s["seq"].append(("skill", bare_skill(name)))

    for o in recs(path):
        if skip and o.get("id") in skip:
            continue
        t = o.get("type")
        if t == "custom" and o.get("customType") == "fablepowers-child":
            d = o.get("data") if isinstance(o.get("data"), dict) else {}
            if d.get("childSessionId"):
                s["children"].append(d["childSessionId"])
            continue
        if t == "custom_message" and o.get("customType") == "fablepowers-result":
            text = text_of(o.get("content"))
            if PI_APPROVED.match(text):
                k = PI_KEY.search(text) or PI_DESIGN.search(text)
                s["seq"].append(("approved", k.group(1) if k else ""))
            continue
        if t != "message":
            continue
        s["messages"] += 1
        m = o.get("message") or {}
        if m.get("role") == "user":
            text = text_of(m.get("content"))
            s["user_turns"] += 1; s["seq"].append(("user", text[:60]))
            for n in PI_SKILL_TAG.findall(text):  # `/skill:<name>`
                skill(pi_skill(n))
            continue
        if m.get("role") != "assistant":
            continue
        u = m.get("usage") or {}
        s["out"] += u.get("output") or 0
        c = u.get("cost")
        costs.append((c.get("total") or 0.0) if isinstance(c, dict) else 0.0)
        if m.get("model"):
            s["models"][m["model"]] += 1
        for b in m.get("content") or []:
            if not isinstance(b, dict) or b.get("type") != "toolCall":
                continue
            n, i = b.get("name"), b.get("arguments") if isinstance(b.get("arguments"), dict) else {}
            if n == "read":
                p = i.get("path") if isinstance(i.get("path"), str) else ""
                for x in SKILL_READ.finditer(p):
                    skill(pi_skill(x.group(1), x.group(0)))
            elif n in PI_EDIT_TOOLS:
                s["edits"] += 1; s["seq"].append(("edit", i.get("path") or ""))
            elif n == "bash":
                cmd = i.get("command") if isinstance(i.get("command"), str) else ""
                for x in cx_skill_reads(cmd):
                    skill(pi_skill(x.rsplit(":", 1)[-1], x))
                if WRITE_RE.search(cmd):
                    s["bash_writes"] += 1; s["seq"].append(("edit", "bash-write"))
            elif n == "fablepowers_ask_approval":
                s["seq"].append(("ask", ""))
            elif n in ("fablepowers_dispatch", "subagent"):
                s["spawns"].append(pi_spawn(n, i))
    s["cost"] = math.fsum(costs)
    return s


def read_pi(a):
    """Pi reader: one record per root session under the sessions dir.

    Handles the flat `--session-dir` layout (`<dir>/*.jsonl`) and Pi's default one
    (`<dir>/--<cwd>--/*.jsonl`); files without a session header are ignored. A
    child is linked by its parent's `fablepowers-child` entry, else by its
    directory (`fablepowers-children/<parent-id>/`, as `pi/fablepowers.ts`
    places it, which also covers killed parents that wrote no entry).
    Descendants at any depth roll up into the root's subs; children whose root
    is missing go to one `(orphan)` record per missing parent.

    A fork or clone (`/fork`, `/clone`) is a new session that repeats its
    source's entries with their entry ids (its header's `parentSession` names
    the source file, which is not needed here). Each entry id is counted once in
    the whole store, in the earliest session holding it (header timestamp, then
    file name, then path), so nothing is counted twice even when a fork's source
    or a middle link of the chain was deleted. Pi's ids are 8 random hex
    digits, unique per file only, so an unrelated session sharing an id loses
    that entry; the chance is negligible. A root with no counted message entries
    (an unused clone) and no descendants is left out, as on OpenCode."""
    base = a.pi_sessions
    if not os.path.isdir(base):
        return [], f"no pi logs at {base}"
    sess = {}  # id -> dict(path, ts, proj, par, scan)
    for d, _, names in os.walk(base):
        for n in names:
            if not n.endswith(".jsonl"):
                continue
            f = os.path.join(d, n)
            h = pi_header(f)
            if h is None or h["id"] in sess:
                continue
            up = os.path.dirname(f)
            par = os.path.basename(up) if os.path.basename(os.path.dirname(up)) == CHILDREN_DIR else None
            ts = h.get("timestamp") if isinstance(h.get("timestamp"), str) else ""
            sess[h["id"]] = dict(path=f, start=ts, ts=ts[:10], proj=path_project(h.get("cwd")), par=par)
    seen = set()  # entry ids already held by an earlier session; undated headers go last
    for x in sorted(sess.values(), key=lambda x: (not x["start"], x["start"], os.path.basename(x["path"]), x["path"])):
        ids = pi_entry_ids(x["path"])
        x["scan"] = scan_pi(x["path"], frozenset(ids & seen))
        seen |= ids
    for sid, x in sess.items():  # the parent's entry wins over the directory
        for c in x["scan"]["children"]:
            if c in sess and c != sid:
                sess[c]["par"] = sid

    def root_of(sid):
        seen = set()
        while sess[sid]["par"] is not None:
            par = sess[sid]["par"]
            if par not in sess or sid in seen:
                return None, par
            seen.add(sid); sid = par
        return sid, None

    groups = collections.defaultdict(list)  # root id or ("orphan", missing parent) -> descendant ids
    for sid, x in sess.items():
        if x["par"] is not None:
            r, missing = root_of(sid)
            groups[r if r else ("orphan", missing)].append(sid)

    def subs_of(kids):
        return [dict(models=sess[c]["scan"]["models"], out=sess[c]["scan"]["out"], cost=sess[c]["scan"]["cost"],
                     edits=sess[c]["scan"]["edits"]) for c in sorted(kids, key=lambda c: sess[c]["path"])]

    rows = []
    for sid, x in sorted(sess.items(), key=lambda kv: kv[1]["path"]):
        if x["par"] is not None or not x["ts"] or (a.since and x["ts"] < a.since):
            continue
        s = x["scan"]
        if not s["messages"] and not groups.get(sid):
            continue
        rows.append(dict(harness="pi", ts=x["ts"], proj=x["proj"], models=s["models"], user_turns=s["user_turns"],
                         out=s["out"], cost=s["cost"], skills=s["skills"], spawns=s["spawns"], edits=s["edits"],
                         bash_writes=s["bash_writes"], seq=s["seq"], subs=subs_of(groups.get(sid, []))))
    for key in sorted((k for k in groups if isinstance(k, tuple)), key=lambda k: min(sess[c]["path"] for c in groups[k])):
        first = sess[min(groups[key], key=lambda c: (sess[c]["ts"], sess[c]["path"]))]
        if not first["ts"] or (a.since and first["ts"] < a.since):
            continue
        proj = "(orphan) " + first["proj"]
        rows.append(dict(harness="pi", ts=first["ts"], proj=proj if len(proj) <= 34 else proj[:32] + "..",
                         models=collections.Counter(), user_turns=0, out=0, cost=0.0, skills=[], spawns=[], edits=0,
                         bash_writes=0, seq=[], subs=subs_of(groups[key])))
    return rows, None


READERS = {"claude": read_claude, "codex": read_codex, "opencode": read_opencode, "pi": read_pi}


def harness_list(value):
    """`all`, or a comma list of harness names -> the selected names in canonical order."""
    names = [n.strip() for n in value.split(",")]
    if "all" in names:
        names = [n for n in names if n != "all"] + list(HARNESSES)
    bad = [n for n in names if n not in HARNESSES]
    if bad or not names:
        raise argparse.ArgumentTypeError(
            f"unknown harness {', '.join(repr(n) for n in bad) or repr(value)} (choose from all, {', '.join(HARNESSES)})")
    return [n for n in HARNESSES if n in names]


short = lambda m: (m or "?").replace("claude-", "")
LEGEND = "approval-gap column: user turns between design-spec and first implementation action ('-' = no design-spec; 0 with an AskUserQuestion approval still counts as approved — check the ASK text)"


def print_claude_only(rows, since):
    """The pre-multi-harness report, byte for byte: path order, unsorted subagent
    glob order, the same summation order and the blank line when nothing was output."""
    print(f"{'date':10} {'project':34} {'main':10} {'usr':>3} {'mainOut':>9} {'subOut':>8} {'sub%':>4} {'mEdit':>5} {'mBashW':>6} {'sEdit':>5} {'$main':>6} {'$sub':>5} {'apprv':>5}  sub-models | skills | spawns")
    T = collections.Counter(); sub_models = collections.Counter(); sub_out_by_model = collections.Counter(); spawn_model = collections.Counter()
    for s in rows:
        so = sum(x["out"] for x in s["subs"]); se = sum(x["edits"] for x in s["subs"]); sc = sum(x["cost"] for x in s["subs"])
        sm = collections.Counter()
        for x in s["subs"]:
            sm.update(x["models"]); sub_models.update(x["models"])
            for k in x["models"]: sub_out_by_model[k] += x["out"]
        for sp in s["spawns"]:
            spawn_model[sp["model"] or "(unset)"] += 1
        pct = f"{so / (so + s['out']):.0%}" if so + s["out"] else "-"
        mm = short(s["models"].most_common(1)[0][0]) if s["models"] else "?"
        skills = ",".join(dict.fromkeys(k.replace("superpowers:", "sp:").replace("fablepowers:", "fp:") for k in s["skills"]))
        spawns = " ".join(f"{k}x{v}" for k, v in collections.Counter(f"{x['role']}" + (f"@{x['model']}" if x["model"] else "") for x in s["spawns"]).items())
        ag = approval_gap(s["seq"]); ag = "-" if ag is None else str(ag)
        print(f"{s['ts']:10} {s['proj']:34} {mm:10} {s['user_turns']:3d} {s['out']:9,d} {so:8,d} {pct:>4} {s['edits']:5d} {s['bash_writes']:6d} {se:5d} {s['cost']:6.0f} {sc:5.0f} {ag:>5}  {' '.join(f'{short(k)}:{v}' for k, v in sm.most_common(2)):20} | {skills} | {spawns}")
        T["main_out"] += s["out"]; T["sub_out"] += so; T["main_edits"] += s["edits"]; T["main_bashw"] += s["bash_writes"]; T["sub_edits"] += se
        T["main_cost"] += s["cost"]; T["sub_cost"] += sc
        for k, v in s["models"].items():
            T["main_msgs_" + short(k)] += v

    tot = T["main_out"] + T["sub_out"]
    print(f"\nsessions: {len(rows)} (since {since})" if since else f"\nsessions: {len(rows)} (all dates)")
    print(f"output tokens: main-loop {T['main_out']:,}  subagents {T['sub_out']:,}  subagent share {T['sub_out'] / tot:.1%}" if tot else "")
    print(f"file edits: main-loop Edit/Write {T['main_edits']}  main-loop Bash writes {T['main_bashw']}  subagent Edit/Write {T['sub_edits']}")
    print(f"est. spend: main-loop ${T['main_cost']:,.0f}  subagents ${T['sub_cost']:,.0f}")
    print("Agent spawn `model` param:", dict(spawn_model))
    print("subagent output tokens by actual model:", {short(k): f"{v:,}" for k, v in sub_out_by_model.most_common()})
    print(LEGEND)


def sub_cost(s):
    """Sum of the subagents' recorded/estimated costs; None when neither the session
    nor any subagent carries a cost (Codex logs no price)."""
    known = [x["cost"] for x in s["subs"] if x["cost"] is not None]
    if not known and s["cost"] is None:
        return None
    return math.fsum(known)


def money(v, width):
    return f"{'-':>{width}}" if v is None else f"{v:{width}.2f}"


def summary_line(label, rows):
    mo = sum(s["out"] for s in rows); so = sum(x["out"] for s in rows for x in s["subs"])
    me = sum(s["edits"] for s in rows); sh = sum(s["bash_writes"] for s in rows)
    se = sum(x["edits"] for s in rows for x in s["subs"])
    costs = [c for s in rows for c in [s["cost"]] + [x["cost"] for x in s["subs"]] if c is not None]
    spend = f"${math.fsum(costs):,.2f}" if costs else "n/a"
    share = f"{100 * so / (mo + so):.1f}" if mo + so else "-"
    spawns = collections.Counter(sp["model"] or "(unset)" for s in rows for sp in s["spawns"])
    return (f"{label} sessions {len(rows)}  out main {mo:,} sub {so:,} ({share}% sub)  edits main {me} shell {sh} sub {se}"
            f"  spend {spend}  spawns {dict(spawns)}")


def model_cell(m):
    """A model id for a table cell: no `claude-` and no provider prefix
    (`deepseek/deepseek-v4-flash` -> `deepseek-v4-flash`)."""
    return short(m).rsplit("/", 1)[-1]


def fit(text, width):
    """Pad to `width`, or cut to it with a trailing `..`."""
    return f"{text:{width}}" if len(text) <= width else text[:width - 2] + ".."


def print_multi(rows, notes, selected):
    """One date-sorted table with a harness column, a summary line per harness, an
    `all` line, then the legend. Costs print with 2 decimals (`-` = not recorded),
    and are summed with fsum so the totals do not depend on file order. Model
    cells drop provider prefixes; the `main` cell is 18 wide, longer ids are cut.
    mainOut and subOut are 10 wide (up to 99,999,999 aligned)."""
    rows = sorted(rows, key=lambda s: s["ts"])
    print(f"{'date':10} {'h':2} {'project':34} {'main':18} {'usr':>3} {'mainOut':>10} {'subOut':>10} {'sub%':>4} {'mEdit':>5} {'mBashW':>6} {'sEdit':>5} {'$main':>9} {'$sub':>8} {'apprv':>5}  sub-models | skills | spawns")
    sub_out_by_model = collections.Counter()
    for s in rows:
        so = sum(x["out"] for x in s["subs"]); se = sum(x["edits"] for x in s["subs"])
        sm = collections.Counter()
        for x in s["subs"]:
            sm.update(x["models"])
            for k in x["models"]: sub_out_by_model[k] += x["out"]
        pct = f"{so / (so + s['out']):.0%}" if so + s["out"] else "-"
        mm = fit(model_cell(s["models"].most_common(1)[0][0]) if s["models"] else "?", 18)
        skills = ",".join(dict.fromkeys(k.replace("superpowers:", "sp:").replace("fablepowers:", "fp:") for k in s["skills"]))
        spawns = " ".join(f"{k}x{v}" for k, v in collections.Counter(f"{x['role']}" + (f"@{x['model']}" if x["model"] else "") for x in s["spawns"]).items())
        ag = approval_gap(s["seq"]); ag = "-" if ag is None else str(ag)
        print(f"{s['ts']:10} {s['harness']:2} {s['proj']:34} {mm} {s['user_turns']:3d} {s['out']:10,d} {so:10,d} {pct:>4} {s['edits']:5d} {s['bash_writes']:6d} {se:5d} {money(s['cost'], 9)} {money(sub_cost(s), 8)} {ag:>5}  {' '.join(f'{model_cell(k)}:{v}' for k, v in sm.most_common(2)):20} | {skills} | {spawns}")

    print()
    for name in selected:
        h = HARNESSES[name]
        mine = [s for s in rows if s["harness"] == h]
        if mine or not notes.get(name):
            print(summary_line(h, mine))
        if notes.get(name):
            print(f"{h} note: {notes[name]}")
    print(summary_line("all", rows))
    print("subagent output tokens by actual model:", {short(k): f"{v:,}" for k, v in sub_out_by_model.most_common()})
    print(LEGEND)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--harness", type=harness_list, default="all",
                    help="all (default), or a comma list of: " + ", ".join(HARNESSES)
                    + ". `claude` alone prints the legacy Claude-only report.")
    ap.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--codex-home", default=os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"),
                    help="Codex home; rollouts are read from its sessions/ (default: $CODEX_HOME or ~/.codex)")
    ap.add_argument("--opencode-db", default=os.path.join(
                        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "opencode", "opencode.db"),
                    help="OpenCode SQLite db, opened read-only (default: $XDG_DATA_HOME/opencode/opencode.db or ~/.local/share/opencode/opencode.db)")
    ap.add_argument("--pi-sessions", default=os.environ.get("PI_CODING_AGENT_SESSION_DIR") or os.path.join(
                        os.environ.get("PI_CODING_AGENT_DIR") or os.path.expanduser("~/.pi/agent"), "sessions"),
                    help="Pi sessions dir (default: $PI_CODING_AGENT_SESSION_DIR, else $PI_CODING_AGENT_DIR/sessions or ~/.pi/agent/sessions)")
    ap.add_argument("--since", default=None, help="only sessions whose first timestamp is >= this date (default: all)")
    a = ap.parse_args()

    rows, notes = [], {}
    for name in a.harness:
        recs_, note = READERS[name](a)
        rows.extend(recs_)
        if note:
            notes[name] = note
    if a.harness == ["claude"]:
        print_claude_only(rows, a.since)
    else:
        print_multi(rows, notes, a.harness)


if __name__ == "__main__":
    main()
