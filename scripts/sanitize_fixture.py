#!/usr/bin/env python3
"""Allowlist sanitiser for the session-log fixtures of tests/analysis/.

A dev tool, not shipped behavior: it turns real Codex / Pi / OpenCode session logs
into committable fixtures for the analyze_delegation.py readers. Everything not
known to be safe is replaced; nothing is copied through by default.

What survives:
  * structure: record/entry/message types, key names the readers use, list shapes;
  * identifiers: session/thread/turn/call ids, tool names, model ids, agent ids,
    seat names, timestamps, every number and boolean (tokens, costs, exit codes);
  * signals the readers key on, rewritten into synthetic equivalents:
      - a SKILL.md path keeps its `skills/<name>/SKILL.md` (or Pi wrapper
        `pi/skills/fablepowers-<name>/SKILL.md`) tail under
        /fixture/plugins/fablepowers/ (or /fixture/plugins/other/);
      - a shell command keeps the verb of each segment that reads a SKILL.md, its
        first verb, and a synthetic write marker iff the original matched the
        legacy write heuristic (WRITE_RE) or carried an apply_patch heredoc;
      - free text keeps a leading `fablepowers-seat:` line, a leading `/x` or `$x`
        command token, `<skill name=...>` tags (Pi), `<skill><name>..</name>
        <path>..</path>` blocks (Codex `$skill` selections), the fablepowers
        approval-gate prefix (approved / withdrew / not recorded / nothing
        pending), and the
        legacy role() keyword of the original (so that heuristic still matches);
      - a file path becomes /fixture/<proj>/[docs/specs|docs/plans|...]/f<N><ext>,
        keeping the spec/plan directory class and the extension.
What is dropped outright: Codex base_instructions, encrypted_content,
aggregated_output, parsed_cmd, stdout/stderr, diff bodies, creator_*, git,
rate_limits; Pi write.content, edit bodies, childSessionFile/Dir, thinking
signatures; OpenCode state.output/content, summary_diffs, metadata, permission.

Usage:
    sanitize_fixture.py codex ROLLOUT.jsonl... --out DIR
    sanitize_fixture.py pi SESSION.jsonl... --root DIR --out DIR
    sanitize_fixture.py opencode --db PATH --session ROOT_ID... --out FILE.sql
    sanitize_fixture.py check {codex|pi} RAW SANITISED   (signal equality, M2)
    sanitize_fixture.py check opencode --db PATH --sql FILE.sql --session ID...

The `check` mode compares the reader-relevant signals of a raw source and its
sanitised copy (tokens, models, tool calls, skill reads, write markers, seat
lines, approval prefixes, spawns, links) and prints `equal` or the difference.
Raw logs are only read: databases are opened `mode=ro`.

Stdlib only.
"""
import argparse, collections, json, os, re, sqlite3, sys

WRITE_RE = re.compile(r"cat\s*>|<<\s*'?EOF|sed\s+-i|tee\s|>\s*\S+\.(py|ts|tsx|js|dart|md|json|ya?ml|toml|sh|css|html)")
SAFE = re.compile(r"^[A-Za-z0-9_.:+=-]{0,64}$")
SAFE_SLASH = re.compile(r"^[A-Za-z0-9_.:+=-]+(/[A-Za-z0-9_.:+=-]+){0,4}$")
SKILL_TAIL = re.compile(r"((?:pi/)?skills/[A-Za-z0-9_-]+/SKILL\.md)")
CX_SKILL = re.compile(r"<skill>\s*<name>([A-Za-z0-9:_-]+)</name>\s*<path>([^<]*)</path>")
SKILL_TAG = re.compile(r"<skill\s+name=\"([A-Za-z0-9:_-]+)\"(?:\s+location=\"([^\"]*)\")?")
ROLE_WORDS = [("reviewer", r"review|critique|audit|verify|spec.?check|adversarial"),
              ("implementer", r"implement|write the code|fix the|apply|refactor|task \d|build"),
              ("explorer", r"explore|search|find|locate|map|research|investigate|analy")]
ROLE_TEXT = {"reviewer": "review placeholder", "implementer": "implement placeholder",
             "explorer": "explore placeholder", "other": "placeholder text"}
TEXT = "placeholder text"
PATH_DIRS = {"docs", "specs", "spec", "plans", "plan", "src", "lib", "tests", "test"}
USER = os.environ.get("USER") or ""
HOME = os.path.expanduser("~")


def bad(s):
    """A string that must never survive verbatim."""
    low = s.lower()
    return bool((USER and USER.lower() in low) or HOME in s or "/home/" in s or "/tmp/" in s
                or "colony" in low or "@" in s)


class Ctx:
    """Per-session state: the project name and a stable path mapping."""

    def __init__(self, proj, cwd=None):
        self.proj, self.cwd, self.paths = proj, cwd, {}

    def path(self, p):
        if not isinstance(p, str) or not p:
            return p
        m = SKILL_TAIL.search(p)
        if m:
            root = "fablepowers" if "fablepowers" in p else "other"
            return f"/fixture/plugins/{root}/{m.group(1)}"
        if p not in self.paths:
            rel = p
            if self.cwd and p.startswith(self.cwd.rstrip("/") + "/"):
                rel = p[len(self.cwd.rstrip("/")) + 1:]
            parts = [x for x in rel.split("/") if x]
            dirs = [x for x in parts[:-1] if x in PATH_DIRS]
            ext = os.path.splitext(parts[-1])[1] if parts else ""
            ext = ext if re.fullmatch(r"\.[A-Za-z0-9]{1,6}", ext or "") else ""
            self.paths[p] = "/".join([f"/fixture/{self.proj}"] + dirs + [f"f{len(self.paths) + 1}{ext}"])
        return self.paths[p]


def role_of(text):
    p = (text or "")[:600].lower()
    for r, rx in ROLE_WORDS:
        if re.search(rx, p):
            return r
    return "other"


def gate_text(raw):
    """fablepowers approval-gate result text -> its synthetic equivalent."""
    t = raw or ""
    m = re.match(r"fablepowers approval gate: the user (approved|withdrew) design", t)
    if m:
        tail = "the approval is recorded." if m.group(1) == "approved" else "the approval is withdrawn."
        return f"fablepowers approval gate: the user {m.group(1)} design `docs/specs/f1.md` (key `k1`); {tail}"
    m = re.match(r"fablepowers approval gate: `?([/$]fablepowers:[a-z-]+)`? may not have been recorded", t)
    if m:
        return f"fablepowers approval gate: `{m.group(1)}` may not have been recorded: placeholder."
    m = re.match(r"fablepowers approval gate: nothing is pending, so `?([/$]fablepowers:[a-z-]+)`? recorded nothing", t)
    if m:
        return f"fablepowers approval gate: nothing is pending, so {m.group(1)} recorded nothing."
    if t.startswith("fablepowers approval gate"):
        return "fablepowers approval gate: placeholder."
    return None


def text(raw, ctx, spawn=False):
    """Free text -> placeholder, keeping the signals listed in the module doc. Every
    placeholder carries the legacy role() keyword of the original (`spawn` is kept
    for call sites that name a dispatch prompt)."""
    if not isinstance(raw, str):
        return raw
    g = gate_text(raw)
    if g:
        return g
    out = []
    first = raw.lstrip().split("\n", 1)[0]
    if first.startswith("fablepowers-seat:"):
        seat = first.split(":", 1)[1].strip().split()[0] if first.split(":", 1)[1].strip() else ""
        out.append("fablepowers-seat: " + (seat if SAFE.match(seat) and not bad(seat) else "x"))
    m = re.match(r"\s*([/$][A-Za-z0-9:_-]{1,48})(?=\s|$)", raw)
    if m and not bad(m.group(1)):
        out.append(m.group(1))
    for name, loc in CX_SKILL.findall(raw):
        out.append(f"<skill>\n<name>{name}</name>\n<path>{ctx.path(loc)}</path>\n</skill>")
    for name, loc in SKILL_TAG.findall(raw):
        out.append(f'<skill name="{name}" location="{ctx.path(loc) if loc else ""}">' + "</skill>")
    if raw.strip():
        out.append(ROLE_TEXT[role_of(raw)])
    return "\n".join(out)


def command(raw, ctx):
    """Shell command -> verbs + SKILL.md reads + a write marker iff the original had one."""
    if not isinstance(raw, str):
        return raw
    segs = [s.strip() for s in re.split(r"&&|\|\||;|\||\n", raw) if s.strip()]

    def verb(seg):
        tok = os.path.basename(seg.split()[0]) if seg.split() else ""
        return tok if re.fullmatch(r"[a-z][a-z0-9_.+-]{0,20}", tok) and not bad(tok) else "cmd"

    out = [verb(segs[0])] if segs else ["cmd"]
    for seg in segs:
        for m in re.finditer(r"\S*" + SKILL_TAIL.pattern, seg):
            out.append(f"{verb(seg)} {ctx.path(m.group(0))}")
    if "*** Begin Patch" in raw:
        out.append("apply_patch <<'PATCH' *** Begin Patch")
    if WRITE_RE.search(raw):
        out.append(f"cat > /fixture/{ctx.proj}/out.txt")
    s = "; ".join(dict.fromkeys(out))
    if bool(WRITE_RE.search(s)) != bool(WRITE_RE.search(raw)):
        s = "; ".join(["cmd"] + out[1:])
    return s


def scalar(v, key, ctx):
    """Generic value policy for keys without a specific rule."""
    if not isinstance(v, str):
        return v
    if v == "" or (SAFE.match(v) and not bad(v)):
        return v
    if key in ("model", "modelId", "model_provider", "provider", "providerID", "agent", "id", "api") \
            and SAFE_SLASH.match(v) and not bad(v):
        return v
    if key == "agent_path" and re.fullmatch(r"(/[A-Za-z0-9_.-]+){1,4}", v) and not bad(v):
        return v
    if v.startswith("/") or v.startswith("~"):
        return ctx.path(v)
    return "x"


def walk(v, ctx, rules, key=None, path=()):
    """Recursive allowlist walk. `rules(key, value, ctx, path)` returns DROP, a
    replacement, or KEEP (walk on with the generic policy)."""
    r = rules(key, v, ctx, path)
    if r is DROP:
        return DROP
    if r is not KEEP:
        return r
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            y = walk(x, ctx, rules, k, path + (k,))
            if y is DROP:
                continue
            kk = k if (SAFE.match(k) and not bad(k)) else (ctx.path(k) if k.startswith("/") else "k")
            out[kk] = y
        return out
    if isinstance(v, list):
        return [y for y in (walk(x, ctx, rules, key, path) for x in v
                            if not (isinstance(x, dict) and x.get("type") == "encrypted_content")) if y is not DROP]
    return scalar(v, key, ctx)


DROP, KEEP = object(), object()

# ---------------------------------------------------------------- Codex

CX_DROP = {"base_instructions", "encrypted_content", "aggregated_output", "parsed_cmd", "stdout", "stderr",
           "creator_user_id", "creator_account_id", "git", "runtime_workspace_roots", "rate_limits",
           "replacement_history", "retained_context", "resume_metadata", "unified_diff", "diff", "move_path",
           "filesystem", "instructions", "developer_instructions", "thinkingSignature", "summary_text", "raw_content"}
CX_TEXT = {"text", "message", "prompt", "last_agent_message", "summary", "output", "content_text", "description",
           "body", "reason", "explanation", "question", "header"}
CX_ARG_KEEP = {"task_name", "agent_type", "model", "reasoning_effort", "fork_turns", "timeout_ms", "target",
               "sessionID", "ids", "id"}


def cx_rules(key, v, ctx, path):
    if key in CX_DROP:
        return DROP
    if key == "host_skills" and isinstance(v, dict):
        # catalogue stub: names a fablepowers SKILL.md without loading it (must not count as a read)
        return {"body": "skills: design-spec /fixture/plugins/fablepowers/skills/design-spec/SKILL.md",
                "includeInstructions": v.get("includeInstructions", False)}
    if key == "command" and isinstance(v, list):
        argv0 = v[0] if v and v[0] in ("/usr/bin/bash", "/bin/bash", "bash", "/bin/sh", "sh", "/bin/zsh") else "sh"
        return ([argv0, "-lc", command(v[-1], ctx)] if len(v) > 1 else [command(v[-1], ctx)])
    if key == "command" and isinstance(v, str):
        return command(v, ctx)
    if key == "changes" and isinstance(v, dict):
        return {ctx.path(p): {"type": (c or {}).get("type") if isinstance(c, dict) else "update"} for p, c in v.items()}
    if key == "input" and isinstance(v, str):
        # exec JS: keep only which tools it called (and a v1 spawn's model literal)
        calls = []
        for m in re.finditer(r"tools\.([A-Za-z0-9_]+)\((.{0,2000}?)\)", v, re.S):
            mm = re.search(r"model\s*:\s*[\"']([A-Za-z0-9_.:/-]{1,64})[\"']", m.group(2)) if "spawn" in m.group(1) else None
            calls.append(f"tools.{m.group(1)}({{model: \"{mm.group(1)}\"}})" if mm else f"tools.{m.group(1)}({{}})")
        return "; ".join(calls) if calls else "placeholder()"
    if key == "arguments" and isinstance(v, str):
        try:
            a = json.loads(v)
        except ValueError:
            return "{}"
        if not isinstance(a, dict):
            return "{}"
        out = {}
        for k, x in a.items():
            if k in ("message", "prompt", "description"):
                out[k] = text(x, ctx, spawn=True) if isinstance(x, str) and len(x) < 1000 and " " in x else "x"
            elif k in CX_ARG_KEEP:
                out[k] = scalar(x, "model", ctx) if isinstance(x, str) else x
            elif k == "questions":
                out[k] = [{"question": TEXT}]
            elif isinstance(x, (int, float, bool)) or x is None:
                out[k] = x
        return json.dumps(out)
    if key in CX_TEXT and isinstance(v, str):
        if key == "prompt":
            return text(v, ctx, spawn=True)
        return text(v, ctx)
    if key in ("cwd",) and isinstance(v, str):
        return f"/fixture/{ctx.proj}"
    if key == "content" and isinstance(v, str):
        return text(v, ctx)
    return KEEP


def cx_record(o, ctx):
    t = o.get("type")
    if t not in ("session_meta", "turn_context", "response_item", "event_msg", "token_usage_record", "compacted",
                 "world_state"):
        return None
    out = walk(o, ctx, cx_rules)
    return out


def sanitize_codex(paths, outdir, proj_of):
    for p in paths:
        with open(p, errors="replace") as fh:
            lines = fh.readlines()
        meta = json.loads(lines[0]).get("payload", {})
        cwd = meta.get("cwd", "")
        if "colony" in cwd.lower():
            sys.exit(f"refusing {os.path.basename(p)}: other project")
        ctx = Ctx(proj_of(cwd), cwd)
        rel = os.path.relpath(p, os.path.join(os.path.dirname(p), "..", "..", ".."))
        dst = os.path.join(outdir, "sessions", rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w") as out:
            for line in lines:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                r = cx_record(o, ctx)
                if r is not None:
                    out.write(json.dumps(r, separators=(",", ":")) + "\n")
        print(dst)

# ---------------------------------------------------------------- Pi

PI_DROP = {"thinkingSignature", "childSessionFile", "childSessionDir", "textSignature", "responseId",
           "errorMessage", "parameters", "constrainedSampling", "edits", "oldText", "newText", "oldString",
           "newString", "diff"}


def pi_rules(key, v, ctx, path):
    if key in PI_DROP:
        return DROP
    if key == "cwd" and isinstance(v, str):
        return f"/fixture/{ctx.proj}"
    if key == "sections" and isinstance(v, dict):
        return {k: TEXT for k in v}
    if key == "toolsAdded" and isinstance(v, list):
        return [{"name": scalar(x.get("name"), "name", ctx)} for x in v if isinstance(x, dict)]
    if key == "arguments" and isinstance(v, dict):
        out = {}
        for k, x in v.items():
            if k == "path":
                out[k] = ctx.path(x)
            elif k == "command":
                out[k] = command(x, ctx)
            elif k in ("seat", "model", "timeout"):
                out[k] = scalar(x, "model", ctx)
            elif k in ("task", "prompt", "description", "question"):
                out[k] = text(x, ctx, spawn=True)
            elif k == "content":
                continue
            elif isinstance(x, (int, float, bool)) or x is None:
                out[k] = x
            else:
                out[k] = "x"
        return out
    if key == "content" and isinstance(v, str):
        return text(v, ctx)
    if key in ("text", "thinking", "task", "prompt", "description", "summary") and isinstance(v, str):
        return text(v, ctx)
    if key == "args" and isinstance(v, str):
        return v if SAFE.match(v) and not bad(v) else "x"
    return KEEP


def sanitize_pi(paths, root, outdir, proj_of):
    for p in paths:
        with open(p, errors="replace") as fh:
            lines = fh.readlines()
        hdr = json.loads(lines[0])
        cwd = hdr.get("cwd", "")
        if "colony" in cwd.lower():
            sys.exit(f"refusing {os.path.basename(p)}: other project")
        ctx = Ctx(proj_of(cwd), cwd)
        dst = os.path.join(outdir, os.path.relpath(p, root))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w") as out:
            for line in lines:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                out.write(json.dumps(walk(o, ctx, pi_rules), separators=(",", ":")) + "\n")
        print(dst)

# ---------------------------------------------------------------- OpenCode

OC_TABLES = ("project", "session_v2", "session_message")


def oc_rules(key, v, ctx, path):
    if key in ("snapshot",):
        return DROP
    if key in ("text", "summary", "recent", "description", "message") and isinstance(v, str):
        return text(v, ctx)
    if key == "instructionSources" and isinstance(v, list):
        return [ctx.path(x) if isinstance(x, str) and x.startswith("/") else "x" for x in v]
    return KEEP


def oc_tool(b, ctx):
    name = b.get("name")
    st = b.get("state") or {}
    i = st.get("input") or {}
    ni = {}
    for k, x in i.items():
        if k == "path" or k == "filePath":
            ni[k] = ctx.path(x)
        elif k == "command":
            ni[k] = command(x, ctx)
        elif k in ("agent", "model", "sessionID", "id"):
            ni[k] = scalar(x, "model", ctx)
        elif k in ("prompt", "description"):
            ni[k] = text(x, ctx, spawn=True)
        elif k == "questions":
            ni[k] = [{"question": TEXT, "options": [{"label": "a"}, {"label": "b"}]}]
        elif k in ("content", "oldString", "newString", "code", "edits"):
            continue
        elif k in ("pattern", "include"):
            ni[k] = "x"
        elif isinstance(x, (int, float, bool)) or x is None:
            ni[k] = x
        else:
            ni[k] = "x"
    nst = {"status": scalar(st.get("status"), "status", ctx), "input": ni}
    md = st.get("metadata")
    if isinstance(md, dict):
        nmd = {}
        for k, x in md.items():
            if k in ("sessionID", "status", "name", "exit", "truncated", "count", "matches", "fp_mark"):
                nmd[k] = scalar(x, "model", ctx) if isinstance(x, str) else x
            elif k == "directory" and isinstance(x, str):
                nmd[k] = ctx.path(x + "/SKILL.md").rsplit("/", 1)[0] if "skills/" in x else ctx.path(x)
            elif k == "answers":
                nmd[k] = [["a"] for _ in (x or [])]
        nst["metadata"] = nmd
    if isinstance(st.get("error"), dict):
        nst["error"] = {"type": scalar(st["error"].get("type"), "type", ctx), "message": TEXT}
    out = {k: walk(x, ctx, oc_rules, k) for k, x in b.items() if k != "state"}
    out["state"] = nst
    return out


def oc_data(d, ctx):
    out = {}
    for k, x in d.items():
        if k == "content" and isinstance(x, list):
            out[k] = [oc_tool(b, ctx) if isinstance(b, dict) and b.get("type") == "tool" else walk(b, ctx, oc_rules, k)
                      for b in x]
        else:
            y = walk(x, ctx, oc_rules, k, (k,))
            if y is not DROP:
                out[k] = y
    return out


def sql_lit(v):
    if v is None:
        return "NULL"
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("'", "''") + "'"


def oc_tree(c, roots):
    ids, frontier = list(roots), list(roots)
    while frontier:
        q = "select id from session_v2 where parent_id in (%s)" % ",".join("?" * len(frontier))
        frontier = [r[0] for r in c.execute(q, frontier)]
        ids += frontier
    return ids


def sanitize_opencode(db, roots, out_sql, proj_of):
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    ddl = {n: s for n, s in c.execute("select name, sql from sqlite_master where sql is not null")}
    idx = [s for n, tn, s in c.execute("select name, tbl_name, sql from sqlite_master where type='index' and sql is not null")
           if tn in OC_TABLES]
    ids = oc_tree(c, roots)
    cols = [r[1] for r in c.execute("pragma table_info(session_v2)")]
    lines = ["-- sanitised by scripts/sanitize_fixture.py; DDL copied from opencode.db (sqlite_master)",
             "PRAGMA foreign_keys=OFF;", "BEGIN TRANSACTION;"]
    lines += [ddl[t] + ";" for t in OC_TABLES]
    lines += [s + ";" for s in idx]
    projects = {}
    rows = []
    for sid in ids:
        r = dict(zip(cols, c.execute("select * from session_v2 where id=?", (sid,)).fetchone()))
        if "colony" in (r["directory"] or "").lower():
            sys.exit(f"refusing {sid}: other project")
        proj = proj_of(r["directory"])
        ctx = Ctx(proj, r["directory"])
        pid = projects.setdefault(proj, f"prj_fixture_{len(projects) + 1}")
        keep_num = {"cost", "tokens_input", "tokens_output", "tokens_reasoning", "tokens_cache_read", "tokens_cache_write",
                    "summary_additions", "summary_deletions", "summary_files", "time_created", "time_updated", "time_idle",
                    "time_viewed", "time_compacting", "time_archived", "time_suspended", "resume_attempts"}
        nr = {}
        for k, v in r.items():
            if k in ("id", "parent_id", "fork_session_id"):
                nr[k] = v
            elif k == "project_id":
                nr[k] = pid
            elif k == "directory":
                nr[k] = f"/fixture/{proj}"
            elif k == "slug":
                nr[k] = "fixture-" + sid[-6:].lower()
            elif k == "title":
                nr[k] = TEXT if v else v
            elif k == "version" or k == "agent" or k == "idle_outcome":
                nr[k] = scalar(v, "model", ctx)
            elif k == "model":
                m = json.loads(v) if v else None
                nr[k] = json.dumps({kk: scalar(vv, "model", ctx) for kk, vv in m.items()}, separators=(",", ":")) if isinstance(m, dict) else v
            elif k in keep_num:
                nr[k] = v
            else:
                nr[k] = None
        rows.append(("session_v2", nr))
        for mr in c.execute("select id, session_id, type, seq, time_created, time_updated, data from session_message "
                            "where session_id=? order by seq", (sid,)):
            d = oc_data(json.loads(mr[6]), ctx)
            rows.append(("session_message", dict(id=mr[0], session_id=mr[1], type=mr[2], seq=mr[3], time_created=mr[4],
                                                 time_updated=mr[5], data=json.dumps(d, separators=(",", ":")))))
    pcols = [r[1] for r in c.execute("pragma table_info(project)")]
    for proj, pid in projects.items():
        pr = {k: None for k in pcols}
        pr.update(id=pid, worktree=f"/fixture/{proj}", vcs="git", name=proj, time_created=0, time_updated=0,
                  time_active=0, sandboxes="[]")
        rows.insert(0, ("project", pr))
    for t, r in rows:
        lines.append(f"INSERT INTO {t} ({', '.join(r)}) VALUES ({', '.join(sql_lit(v) for v in r.values())});")
    lines.append("COMMIT;")
    with open(out_sql, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print(out_sql, len(ids), "sessions")

# ---------------------------------------------------------------- signals (M2 check)


def skill_names(s):
    return sorted(re.findall(r"(?:pi/)?skills/([A-Za-z0-9_-]+)/SKILL\.md", s or ""))


def cx_signals(path):
    """Reader-relevant facts of one rollout, independent of free text."""
    sig = collections.Counter()
    for line in open(path, errors="replace"):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        t, p = o.get("type"), o.get("payload") or {}
        if t == "session_meta":
            sig["id=" + str(p.get("id"))] += 1
            sig["ts=" + str(p.get("timestamp"))] += 1
            src = p.get("source")
            if isinstance(src, dict):
                sig["spawn=" + json.dumps(((src.get("subagent") or {}).get("thread_spawn") or {}), sort_keys=True)] += 1
            else:
                sig["source=" + str(src)] += 1
        elif t == "turn_context":
            sig["model=" + str(p.get("model")) + "/" + str(p.get("effort"))] += 1
        elif t == "token_usage_record":
            sig["out+=%s" % (p.get("usage") or {}).get("output_tokens")] += 1
            sig["thread_out=%s" % (p.get("thread_token_usage") or {}).get("output_tokens")] += 1
        elif t == "event_msg" and p.get("type") == "token_count" and p.get("info"):
            sig["tc=%s" % p["info"]["total_token_usage"]["output_tokens"]] += 1
        elif t == "compacted":
            sig["compacted"] += 1
        elif t == "event_msg" and p.get("type") == "item_completed":
            it = p.get("item") or {}
            k = it.get("type")
            sig["item=" + str(k)] += 1
            if k == "UserMessage":
                sig["um.kinds=" + ",".join(x.get("type", "") for x in it.get("content") or [])] += 1
                first = next((x.get("text", "") for x in it.get("content") or [] if x.get("type") == "text"), "")
                sig["um.role=" + role_of(first)] += 1
                if first.lstrip().startswith("fablepowers-seat:"):
                    sig["seat=" + first.lstrip().split("\n")[0].split(":", 1)[1].strip().split()[0]] += 1
            elif k == "CommandExecution":
                cmd = it.get("command")
                cmd = cmd[-1] if isinstance(cmd, list) else (cmd or "")
                sig["cmd.write=%s" % bool(WRITE_RE.search(cmd))] += 1
                sig["cmd.patch=%s" % ("*** Begin Patch" in cmd)] += 1
                for s in skill_names(cmd):
                    sig["skillread=%s/%s" % (s, "fablepowers" in cmd)] += 1
            elif k == "FileChange":
                ch = it.get("changes") or {}
                sig["filechange=%s/%d/%s" % (it.get("status"), len(ch),
                                             ",".join(sorted(bool(re.search(r"specs?/|plans?/|\.md$", x)) and "doc" or "code" for x in ch)))] += 1
            elif k == "CollabAgentToolCall":
                sig["collab=%s/%s/%s/%s" % (it.get("tool"), it.get("model"), it.get("reasoning_effort"),
                                            ",".join(it.get("receiver_thread_ids") or []))] += 1
            elif k == "ContextCompaction":
                sig["ctxcompaction"] += 1
        elif t == "response_item" and p.get("type") in ("function_call", "custom_tool_call"):
            sig["call=%s.%s" % (p.get("namespace"), p.get("name"))] += 1
            if p.get("type") == "function_call":
                try:
                    a = json.loads(p.get("arguments") or "{}")
                except ValueError:
                    a = {}
                if isinstance(a, dict) and p.get("name") == "spawn_agent":
                    sig["spawnargs=" + json.dumps({k: a.get(k) for k in ("task_name", "agent_type", "model",
                                                                         "reasoning_effort")}, sort_keys=True)] += 1
                    sig["spawnrole=" + role_of(a.get("message") or "")] += 1 if " " in (a.get("message") or "") else 0
        elif t == "response_item" and p.get("type") == "message":
            kinds = (p.get("internal_chat_message_metadata_passthrough") or {}).get("content_item_kinds")
            sig["msg.%s=%s" % (p.get("role"), ",".join(kinds or []))] += 1
            for x in p.get("content") or []:
                for name, loc in CX_SKILL.findall(x.get("text") or "") if isinstance(x, dict) else []:
                    sig["selected=%s/%s" % (name, ",".join(skill_names(loc)))] += 1
    return +sig


def pi_signals(path):
    sig = collections.Counter()
    for line in open(path, errors="replace"):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        t = o.get("type")
        if t == "session":
            sig["id=" + str(o.get("id"))] += 1
            sig["ts=" + str(o.get("timestamp"))] += 1
            continue
        sig["entry=" + str(t)] += 1
        if t == "custom":
            d = o.get("data") or {}
            sig["custom=%s/%s" % (o.get("customType"), json.dumps({k: d.get(k) for k in ("seat", "childSessionId", "model",
                                                                                         "exitCode", "parentId")},
                                                                   sort_keys=True))] += 1
        if t == "custom_message":
            c = o.get("content")
            g = gate_text(c if isinstance(c, str) else "")
            sig["result=%s/%s" % (o.get("customType"), (g or "-")[:60])] += 1
        m = o.get("message") or {}
        if t != "message":
            continue
        r = m.get("role")
        sig["role=" + str(r)] += 1
        if r == "assistant":
            u = m.get("usage") or {}
            sig["asst=%s/%s/%s/%s" % (m.get("model"), u.get("output"), u.get("reasoning"), (u.get("cost") or {}).get("total"))] += 1
            for b in m.get("content") or []:
                if isinstance(b, dict) and b.get("type") == "toolCall":
                    n, a = b.get("name"), b.get("arguments") or {}
                    sig["tool=" + str(n)] += 1
                    if n == "read":
                        for s in skill_names(a.get("path")):
                            sig["read=%s/%s" % (s, "fablepowers" in a.get("path", ""))] += 1
                        sig["readdoc=%s" % bool(re.search(r"specs?/|plans?/|\.md$", a.get("path", "")))] += 1
                    if n in ("write", "edit"):
                        sig["%s.doc=%s" % (n, bool(re.search(r"specs?/|plans?/|\.md$", a.get("path", ""))))] += 1
                    if n == "bash":
                        sig["bash.write=%s" % bool(WRITE_RE.search(a.get("command", "")))] += 1
                        for s in skill_names(a.get("command")):
                            sig["bashread=" + s] += 1
                    if n == "fablepowers_dispatch":
                        sig["dispatch=%s/%s" % (a.get("seat"), role_of(a.get("task") or ""))] += 1
        elif r == "user":
            c = m.get("content")
            t2 = c if isinstance(c, str) else " ".join(x.get("text", "") for x in c or [] if isinstance(x, dict))
            sig["user.nonempty=%s/%s" % (bool(t2.strip()), role_of(t2))] += 1
            for name, _ in SKILL_TAG.findall(t2):
                sig["skilltag=" + name] += 1
            mm = re.match(r"\s*([/$][A-Za-z0-9:_-]{1,48})(?=\s|$)", t2)
            if mm:
                sig["slash=" + mm.group(1)] += 1
        elif r == "toolResult":
            sig["toolresult=%s/%s" % (m.get("toolName"), m.get("isError"))] += 1
    return +sig


def oc_signals(conn, ids):
    sig = collections.Counter()
    for sid in ids:
        r = conn.execute("select parent_id, agent, model, time_created, cost, tokens_output, tokens_reasoning from session_v2 "
                         "where id=?", (sid,)).fetchone()
        sig["session=%s/%s" % (sid, json.dumps(r))] += 1
        for typ, seq, data in conn.execute("select type, seq, data from session_message where session_id=? order by seq", (sid,)):
            d = json.loads(data)
            sig["msg=%s/%s/%s" % (sid, seq, typ)] += 1
            if typ in ("assistant", "compaction"):
                sig["tok=%s/%s/%s/%s/%s" % (sid, (d.get("model") or {}).get("id"), (d.get("tokens") or {}).get("output"),
                                            (d.get("tokens") or {}).get("reasoning"), d.get("cost"))] += 1
            if typ == "user":
                mm = re.match(r"\s*([/$][A-Za-z0-9:_-]{1,48})(?=\s|$)", d.get("text") or "")
                sig["user=%s/%s" % (bool((d.get("text") or "").strip()), mm.group(1) if mm else "-")] += 1
            for b in d.get("content") or []:
                if not (isinstance(b, dict) and b.get("type") == "tool"):
                    continue
                st = b.get("state") or {}
                i = st.get("input") or {}
                n = b.get("name")
                s = "tool=%s/%s" % (n, st.get("status"))
                if n == "skill":
                    s += "/" + str(i.get("id"))
                elif n == "subagent":
                    s += "/%s/%s/%s/%s/%s" % (i.get("agent"), i.get("model"), i.get("sessionID"),
                                              (st.get("metadata") or {}).get("sessionID"),
                                              role_of((i.get("description") or "") + " " + (i.get("prompt") or "")))
                elif n == "shell":
                    s += "/write=%s" % bool(WRITE_RE.search(i.get("command") or ""))
                    s += "/" + ",".join(skill_names(i.get("command")))
                elif n in ("write", "edit", "read"):
                    s += "/doc=%s" % bool(re.search(r"specs?/|plans?/|\.md$", i.get("path") or ""))
                    s += "/" + ",".join(skill_names(i.get("path")))
                sig[s] += 1
    return +sig


def diff(a, b):
    if a == b:
        return "equal (%d signals)" % sum(a.values())
    return "DIFFER: raw-only %s ; sanitised-only %s" % (dict(a - b), dict(b - a))

# ---------------------------------------------------------------- CLI


def default_proj(path):
    """Last two path components, safe characters only (e.g. `codex2-repo`)."""
    parts = [x for x in (path or "").rstrip("/").split("/") if x][-2:]
    name = "-".join(re.sub(r"[^A-Za-z0-9_.-]", "", x) for x in parts) or "proj"
    return name if not bad(name) else "proj"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("codex"); a.add_argument("paths", nargs="+"); a.add_argument("--out", required=True)
    a = sub.add_parser("pi"); a.add_argument("paths", nargs="+"); a.add_argument("--root", required=True)
    a.add_argument("--out", required=True)
    a = sub.add_parser("opencode"); a.add_argument("--db", required=True); a.add_argument("--session", nargs="+", required=True)
    a.add_argument("--out", required=True)
    a = sub.add_parser("check"); a.add_argument("harness", choices=["codex", "pi", "opencode"])
    a.add_argument("raw", nargs="?"); a.add_argument("sanitised", nargs="?")
    a.add_argument("--db"); a.add_argument("--sql"); a.add_argument("--session", nargs="*")
    a = ap.parse_args()
    if a.cmd == "codex":
        sanitize_codex(a.paths, a.out, default_proj)
    elif a.cmd == "pi":
        sanitize_pi(a.paths, a.root, a.out, default_proj)
    elif a.cmd == "opencode":
        sanitize_opencode(a.db, a.session, a.out, default_proj)
    elif a.harness == "codex":
        print(diff(cx_signals(a.raw), cx_signals(a.sanitised)))
    elif a.harness == "pi":
        print(diff(pi_signals(a.raw), pi_signals(a.sanitised)))
    else:
        raw = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
        mem = sqlite3.connect(":memory:")
        mem.executescript(open(a.sql).read())
        ids = oc_tree(raw, a.session)
        print(diff(oc_signals(raw, ids), oc_signals(mem, ids)))


if __name__ == "__main__":
    main()
