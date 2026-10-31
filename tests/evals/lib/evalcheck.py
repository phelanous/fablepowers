"""Shared helpers for the live-eval checkers (tests/evals/fixtures/<eval>/check.py).

Stdlib only, Python 3.8+. A checker is run as

    python3 -I tests/evals/fixtures/<eval>/check.py <session.jsonl> <state-dir>

where <session.jsonl> is the orchestrator's transcript, with its subagents in
<session>/subagents/ beside it (the layout Claude Code writes and run-eval.sh
copies), and <state-dir> holds what run-eval.sh captured after the run:

    result.json        the stream-json `result` event
    progress.md        the plan workspace's ledger ('' when absent)
    fablepowers/       the fixture repo's .fablepowers/ tree (reports)
    worktrees.txt      `git worktree list --porcelain`
    branches.txt       `git branch --list 'fp/*'`
    status.txt         `git status --porcelain`
    ignore-check.txt   `git check-ignore -v .worktrees/x`, then `exit <status>`
    tracked-worktrees.txt  paths under .worktrees/ in main's history ('' when none)
    gitignore-head.txt `git show HEAD:.gitignore` ('' when there is none)
    log.txt            `git log --format='%H %P|%s' main`
    first-parent.txt   `git rev-list --first-parent main`
    plus whatever the fixture's post.sh adds.

Each assertion prints one line, `  [PASS] <name> — <detail>` or
`  [FAIL] <name> — <detail>`; signals print `  [SIGNAL] ...` and never fail.
The checker exits 1 when any assertion failed, else 0.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
# SESSION_TIMELINE overrides the timeline script (mutation checks on a copy).
TIMELINE = os.environ.get("SESSION_TIMELINE") or os.path.join(REPO_ROOT, "scripts", "session-timeline.py")

EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")


def load_jsonl(path):
    out = []
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict):
                    out.append(rec)
    except OSError:
        pass
    return out


class Call:
    """One tool_use block, with its tool_result once it arrives."""

    def __init__(self, idx, block, ts, msg_id):
        self.idx = idx
        self.id = block.get("id")
        self.name = block.get("name") or ""
        self.input = block.get("input") if isinstance(block.get("input"), dict) else {}
        self.ts = ts
        self.msg_id = msg_id
        self.result_idx = None
        self.result_ts = None
        self.result_text = ""
        self.is_error = False

    @property
    def command(self):
        return (self.input.get("command") or "") if self.name == "Bash" else ""

    @property
    def path(self):
        return self.input.get("file_path") or self.input.get("notebook_path") or ""

    @property
    def prompt(self):
        return self.input.get("prompt") or ""

    @property
    def subagent_type(self):
        return self.input.get("subagent_type") or ""

    def written_text(self):
        """The text an edit tool writes (Write content, Edit new_string)."""
        parts = [self.input.get("content") or "", self.input.get("new_string") or ""]
        for e in self.input.get("edits") or []:
            if isinstance(e, dict):
                parts.append(e.get("new_string") or "")
        return "\n".join(p for p in parts if isinstance(p, str))


def _result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(_result_text(c.get("text") if isinstance(c, dict) else c) for c in content)
    return ""


def parse_calls(path, main_only=False):
    """Tool calls of one transcript file, in file order. `idx` counts tool_use
    and tool_result blocks together, so `a.idx < b.result_idx` means a was
    issued before b returned."""
    calls, by_id, n = [], {}, 0
    for rec in load_jsonl(path):
        if main_only and rec.get("isSidechain"):
            continue
        msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if rec.get("type") == "assistant" and block.get("type") == "tool_use":
                c = Call(n, block, rec.get("timestamp") or "", msg.get("id"))
                calls.append(c)
                if c.id:
                    by_id[c.id] = c
                n += 1
            elif rec.get("type") == "user" and block.get("type") == "tool_result":
                c = by_id.get(block.get("tool_use_id"))
                if c is not None and c.result_idx is None:
                    c.result_idx = n
                    c.result_ts = rec.get("timestamp") or ""
                    c.result_text = _result_text(block.get("content"))
                    c.is_error = bool(block.get("is_error"))
                n += 1
    return calls


def read_text(path):
    try:
        with open(path, errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


class Session:
    def __init__(self, transcript, state_dir):
        self.transcript = transcript
        self.state_dir = state_dir
        self.calls = parse_calls(transcript, main_only=True)
        session_dir = transcript[:-len(".jsonl")] if transcript.endswith(".jsonl") else transcript
        self.subagents = {}
        sub = os.path.join(session_dir, "subagents")
        if os.path.isdir(sub):
            for name in sorted(os.listdir(sub)):
                if name.startswith("agent-") and name.endswith(".jsonl"):
                    aid = name[len("agent-"):-len(".jsonl")]
                    meta = {}
                    try:
                        meta = json.loads(read_text(os.path.join(sub, "agent-%s.meta.json" % aid)) or "{}")
                    except ValueError:
                        meta = {}
                    self.subagents[aid] = {"meta": meta if isinstance(meta, dict) else {},
                                           "calls": parse_calls(os.path.join(sub, name))}
        self.timeline = self._timeline()
        self.intervals = {i.get("tool_use_id"): i for i in self.timeline.get("intervals", []) if i.get("tool_use_id")}

    def _timeline(self):
        try:
            out = subprocess.run([sys.executable, "-I", TIMELINE, "--json", self.transcript],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, check=False)
            return json.loads(out.stdout.strip().splitlines()[0]) if out.returncode == 0 and out.stdout.strip() else {}
        except (OSError, ValueError, IndexError):
            return {}

    def state(self, name):
        return read_text(os.path.join(self.state_dir, name))

    def progress(self):
        return self.state("progress.md")

    def result(self):
        try:
            data = json.loads(self.state("result.json") or "{}")
        except ValueError:
            data = {}
        return data if isinstance(data, dict) else {}

    def bash(self):
        return [c for c in self.calls if c.name == "Bash"]

    def agent_calls(self):
        return [c for c in self.calls if c.name in ("Agent", "Task")]

    def subagent_for(self, call):
        for aid, a in self.subagents.items():
            if a["meta"].get("toolUseId") == call.id:
                return a
        return None

    def segments(self, call):
        iv = self.intervals.get(call.id)
        return [tuple(s) for s in iv.get("segments", [])] if iv else []

    def report(self, rel):
        """A file under the captured .fablepowers tree, found by its tail."""
        root = os.path.join(self.state_dir, "fablepowers")
        for dirpath, _, files in os.walk(root):
            for f in files:
                p = os.path.join(dirpath, f)
                if p.replace(os.sep, "/").endswith("/" + rel):
                    return read_text(p)
        return ""


# --- dispatch classification ------------------------------------------------

def norm_id(tid):
    tid = (tid or "").strip().lower()
    return tid[1:] if tid.startswith("t") and tid[1:2].isdigit() else tid


def classify_dispatch(call):
    """('merge', id) for a merge fix, ('fix', id) for a fix round, ('task', id)
    for a task dispatch, ('other', '') otherwise. The report path decides
    first, since every dispatch names one; then the task worktree; then the
    heading. Report paths are read with or without a `T` before the id
    (`task-1.md`, and `task-T1-fix1.md` from outputs before the spelling was
    pinned)."""
    p = call.prompt
    m = re.search(r"task-T?([0-9]+[a-z]*)-merge[0-9]+\.md", p, re.I)
    if m:
        return "merge", norm_id(m.group(1))
    m = re.search(r"task-T?([0-9]+[a-z]*)-fix[0-9]+\.md", p, re.I)
    if m:
        return "fix", norm_id(m.group(1))
    m = re.search(r"reports/task-T?([0-9]+[a-z]*)\.md", p, re.I)
    if m:
        return "task", norm_id(m.group(1))
    if "reviewer" in call.subagent_type:
        return "other", ""
    m = re.search(r"\.worktrees/[\w.-]*-t([0-9]+[a-z]*)\b", p, re.I)
    if m:
        return "task", norm_id(m.group(1))
    m = re.search(r"^#{2,3} (?:T|Task )([0-9]+[a-z]*)\b", p, re.I | re.M)
    if m:
        return "task", norm_id(m.group(1))
    return "other", ""


def task_dispatches(session, kind="task"):
    out = {}
    for c in session.agent_calls():
        k, tid = classify_dispatch(c)
        if k == kind:
            out.setdefault(tid, []).append(c)
    return out


def worktree_paths(text):
    return {w.rstrip(".") for w in re.findall(r"\.worktrees/([\w.-]+)", text)}


# --- ledger -------------------------------------------------------------------

def ledger_re(kind, tid):
    """`task 1 |`, `task T1 |`, `check 2 |`. A line may also follow a literal
    `\\n` inside a printf format, as in `printf 'check 1 | …\\ntask 1 | …'`."""
    tid = re.escape(norm_id(tid))
    return re.compile(r"(?:(?<![\w-])|(?<=\\n))%s\s+T?%s\s*\|" % (kind, tid), re.I)


def ledger_lines(session, kind, tid):
    rx = ledger_re(kind, tid)
    return [l for l in session.progress().splitlines() if rx.match(l.strip())]


def round_re(kind, tid):
    """`fix 2-1 |` (a per-task fix round) or `merge 2-1 |` (a merge fix), with
    or without a `T`; never `fix integration-1 |`."""
    tid = re.escape(norm_id(tid))
    return re.compile(r"(?:(?<![\w-])|(?<=\\n))%s\s+T?%s-\d+\s*\|" % (kind, tid), re.I)


def round_lines(session, kind, tid):
    rx = round_re(kind, tid)
    return [l for l in session.progress().splitlines() if rx.match(l.strip())]


def ledger_write_idx(session, kind, tid):
    """Index of the first main-session call that writes a matching ledger
    line: a Bash command naming progress.md, or an edit tool on progress.md."""
    rx = ledger_re(kind, tid)
    for c in session.calls:
        if c.name == "Bash" and "progress.md" in c.command and rx.search(c.command):
            return c.idx
        if c.name in EDIT_TOOLS and c.path.endswith("progress.md") and rx.search(c.written_text()):
            return c.idx
    return None


# --- git commands in the main session ------------------------------------------

def segments_of(command):
    return [s.strip() for s in re.split(r"&&|\|\||;|\n", command) if s.strip()]


GIT_MERGE = re.compile(r"\bgit\b(?:\s+-C\s+\S+)?\s+merge\b")


def merge_calls(session, key, tid):
    """Main-session Bash calls that merge fp/<key>/t<tid> (aborts excluded),
    as (call, segment) pairs."""
    br = re.compile(r"fp/%s/t%s(?![\w])" % (re.escape(key), re.escape(norm_id(tid))), re.I)
    out = []
    for c in session.bash():
        for seg in segments_of(c.command):
            if GIT_MERGE.search(seg) and "--abort" not in seg and br.search(seg):
                out.append((c, seg))
    return out


DENIED = re.compile(r"can't be checked before it runs|requires? approval|was blocked|Claude requested permissions|"
                    r"permission to use .* has been denied|expansion obfuscation|unanalyzable", re.I)


def denied(call):
    """A call the permission layer refused: it never ran."""
    return call.is_error and bool(DENIED.search(call.result_text))


def merge_conflicted(call):
    """A merge that ran and stopped on a conflict (a denied one never ran)."""
    t = call.result_text
    return not denied(call) and ("CONFLICT" in t or "Automatic merge failed" in t)


def merge_succeeded(call):
    t = call.result_text
    return not (call.is_error or "CONFLICT" in t or "Automatic merge failed" in t)


def overlap(segs_a, segs_b):
    return any(sa < eb and sb < ea for sa, ea in segs_a for sb, eb in segs_b)


def iso_seconds(ts):
    import datetime
    t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return t.timestamp()


def concurrency(segment_lists):
    """Active time over wall time for the given agents' segments."""
    segs = sorted((iso_seconds(s), iso_seconds(e)) for sl in segment_lists for s, e in sl)
    if not segs:
        return 0.0
    active = sum(e - s for s, e in segs)
    wall, cur = 0.0, None
    for s, e in segs:
        if cur and s <= cur[1]:
            cur[1] = max(cur[1], e)
            continue
        if cur:
            wall += cur[1] - cur[0]
        cur = [s, e]
    wall += cur[1] - cur[0]
    return active / wall if wall else 0.0


# --- the pre-commit suite rule ------------------------------------------------------

def unheld_parts(runs, parts, full, held):
    """Serialized parts an implementer's runs used without holding them.

    The rule (spec section 1, re-review 1 R1): every implementer runs the
    plan's pre-commit suite, which skips every `serialize` run resource, plus
    the part of each one its task's Touches line names, while holding it; so
    no implementer runs a part it doesn't hold, however many there are.
    `runs` are the command texts it ran; `parts` maps each serialize run
    resource to a regex for the command that runs its part; `full` is a regex
    for the full-suite command, which runs every part; `held` is the set of
    resources on the task's Touches line. Returns (resource, the run's first
    line) pairs, one per resource, in `parts` order."""
    out = []
    for res, rx in parts.items():
        if res in held:
            continue
        hit = next((r for r in runs if rx.search(r) or full.search(r)), None)
        if hit is not None:
            out.append((res, hit.splitlines()[0]))
    return out


# --- reporting ------------------------------------------------------------------

class Checker:
    def __init__(self, title):
        self.title = title
        self.lines = []
        self.failed = 0

    def check(self, name, ok, detail=""):
        self.lines.append("  [%s] %s%s" % ("PASS" if ok else "FAIL", name, (" — " + detail) if detail else ""))
        if not ok:
            self.failed += 1
        return ok

    def signal(self, name, detail):
        self.lines.append("  [SIGNAL] %s — %s" % (name, detail))

    def finish(self):
        print(self.title)
        for l in self.lines:
            print(l)
        print("%s: %s" % (self.title, "FAIL (%d)" % self.failed if self.failed else "PASS"))
        return 1 if self.failed else 0


def args():
    if len(sys.argv) != 3:
        print("usage: check.py <session.jsonl> <state-dir>", file=sys.stderr)
        sys.exit(2)
    return sys.argv[1], sys.argv[2]


# --- assertions shared by several evals ------------------------------------------

def assert_stopped(s, c, task_ids, name="stopped-before-review"):
    """The run ended on its own after the last task line, before integration
    review: result success, every task line in, no reviewer dispatched, no
    review line in the ledger."""
    res = s.result()
    missing = [t for t in task_ids if not ledger_lines(s, "task", t)]
    reviewers = [x for x in s.agent_calls() if "reviewer" in x.subagent_type]
    review_lines = [l for l in s.progress().splitlines() if re.match(r"\s*review\s", l)]
    problems = []
    if res.get("subtype") != "success" or res.get("is_error"):
        problems.append("result subtype %r" % res.get("subtype"))
    if missing:
        problems.append("no task line for %s" % ", ".join(missing))
    if reviewers:
        problems.append("%d reviewer dispatch(es)" % len(reviewers))
    if review_lines:
        problems.append("review ledger line: %s" % review_lines[0].strip())
    return c.check(name, not problems, "; ".join(problems) or "result success, task lines in, no review")


def assert_cleanup(s, c, key, name="worktrees-and-branches-gone"):
    wts = [l for l in s.state("worktrees.txt").splitlines() if l.startswith("worktree ")]
    brs = [l.strip(" *+") for l in s.state("branches.txt").splitlines() if ("fp/%s/" % key) in l]
    ok = len(wts) == 1 and not brs
    return c.check(name, ok, "%d worktree(s), task branches: %s" % (len(wts), ", ".join(brs) or "none"))


def assert_merges_no_ff(s, c, key, tids, required, name="merges-no-ff"):
    """Every merge of a task branch uses --no-ff; tasks in `required` must
    have at least one merge."""
    problems = []
    for t in tids:
        ms = merge_calls(s, key, t)
        if t in required and not ms:
            problems.append("no merge of fp/%s/t%s" % (key, t))
        for call, seg in ms:
            if "--no-ff" not in seg:
                problems.append("merge without --no-ff: %s" % seg)
    return c.check(name, not problems, "; ".join(problems) or "every task-branch merge is --no-ff")


def assert_check_after_merges(s, c, key, tids, name="check-line-after-each-merge"):
    """After each successful merge of a task branch, or after a task run in
    place returns (no merge at all), a `check <id>` ledger line is written,
    and the ledger's last check line for the task is PASS."""
    problems = []
    dispatches = task_dispatches(s)
    for t in tids:
        ok_merges = [call for call, _ in merge_calls(s, key, t) if merge_succeeded(call)]
        if ok_merges:
            after = max(m.idx for m in ok_merges)
        else:
            ds = [d for d in dispatches.get(t, []) if d.result_idx is not None]
            if not ds:
                problems.append("T%s: neither a merge nor a returned dispatch" % t)
                continue
            after = max(d.result_idx for d in ds)
        rx = ledger_re("check", t)
        writes = [x.idx for x in s.calls if x.idx > after and (
            (x.name == "Bash" and "progress.md" in x.command and rx.search(x.command)) or
            (x.name in EDIT_TOOLS and x.path.endswith("progress.md") and rx.search(x.written_text())))]
        lines = ledger_lines(s, "check", t)
        if not writes:
            problems.append("T%s: no check line written after its merge" % t)
        elif not lines or "PASS" not in lines[-1].upper():
            problems.append("T%s: last check line is not PASS (%s)" % (t, lines[-1].strip() if lines else "none"))
    return c.check(name, not problems, "; ".join(problems) or "a PASS check line follows each merge")
