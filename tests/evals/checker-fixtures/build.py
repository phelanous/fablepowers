"""Build the synthetic checker fixtures for tests/evals/test-checkers.sh.

Usage:
    python3 -I tests/evals/checker-fixtures/build.py           # (re)write the fixtures
    python3 -I tests/evals/checker-fixtures/build.py --check   # exit 1 if the committed ones differ

Every fixture is synthetic: a transcript in Claude Code's layout (the shapes
seen in the T0 spike: one content block per assistant line, parallel tool_use
blocks sharing a message id, subagents under <session>/subagents/ with a
.meta.json carrying toolUseId) plus the state files run-eval.sh captures. No
live transcript goes in here; they can hold private data.

Per eval there is one `pass` case that satisfies every assertion, and one
doctored case per assertion that violates only that assertion. Each case's
`expect` file holds `pass` or the name of the one assertion that must fail;
a replay of an older release's behaviour, which breaks several at once, lists
each of them on its own line and must fail exactly that set.
"""
import datetime
import filecmp
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = "/tmp/tmp.EVALFIX/repo"
WS = ROOT + "/.fablepowers/demo"
PLUG = "/opt/fablepowers"
SCRATCH = "/tmp/claude-1000/evalfix/scratchpad"
T0 = datetime.datetime(2026, 10, 31, 12, 0, 0, tzinfo=datetime.timezone.utc)


IGNORED = ".worktrees/.gitignore:1:*\t.worktrees/x\nexit 0\n"


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % (t.microsecond // 1000)


class Run:
    def __init__(self):
        self.t = T0
        self.n = 0
        self.main = []
        self.subs = {}
        self.state = {
            "progress.md": "# Progress: docs/plans/demo.md\n",
            "result.json": json.dumps({"type": "result", "subtype": "success", "is_error": False,
                                       "total_cost_usd": 1.5, "num_turns": 40, "permission_denials": []}),
            "worktrees.txt": "worktree %s\nHEAD 1111111111111111111111111111111111111111\nbranch refs/heads/main\n\n" % ROOT,
            "branches.txt": "",
            "status.txt": "",
            "ignore-check.txt": IGNORED,
            "tracked-worktrees.txt": "",
            "gitignore-head.txt": "__pycache__/\n*.pyc\n",
            "log.txt": "",
            "first-parent.txt": "",
        }
        self.files = {}
        self.combine = False  # write each task's check and task lines in one printf

    def tick(self, sec=2):
        self.t += datetime.timedelta(seconds=sec)
        return iso(self.t)

    def nid(self, prefix):
        self.n += 1
        return "%s%04d" % (prefix, self.n)

    def line(self, rec, agent=None):
        (self.subs[agent]["records"] if agent else self.main).append(rec)

    def use(self, name, inp, msg=None, agent=None, t=None):
        tid = self.nid("toolu_fix")
        rec = {"type": "assistant", "timestamp": t or self.tick(), "isSidechain": bool(agent),
               "message": {"id": msg or self.nid("msg_fix"), "role": "assistant",
                           "content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]}}
        if agent:
            rec["agentId"] = agent
        self.line(rec, agent)
        return tid

    def res(self, tid, text="", err=False, agent=None, t=None, extra=None, meta=None):
        rec = {"type": "user", "timestamp": t or self.tick(), "isSidechain": bool(agent),
               "message": {"role": "user", "content": [
                   {"tool_use_id": tid, "type": "tool_result", "content": text, "is_error": err}]}}
        if agent:
            rec["agentId"] = agent
        if extra:
            rec["toolUseResult"] = extra
        if meta:
            rec.update(meta)
        self.line(rec, agent)

    def bash(self, cmd, out="", err=False):
        tid = self.use("Bash", {"command": cmd, "description": "run"})
        self.res(tid, out or "(Bash completed with no output)", err)
        return tid

    def text(self, s):
        self.line({"type": "assistant", "timestamp": self.tick(), "isSidechain": False,
                   "message": {"id": self.nid("msg_fix"), "role": "assistant", "content": [{"type": "text", "text": s}]}})

    def ledger(self, entry):
        self.bash("printf '%%s\\n' '%s' >> %s/progress.md" % (entry, WS))
        self.state["progress.md"] += entry + "\n"

    def ledger_pair(self, check, task):
        """The check and task lines, as one printf when `combine` is set."""
        if not self.combine:
            self.ledger(check)
            self.ledger(task)
            return
        self.bash("printf '%s\\n%s\\n' >> %s/progress.md" % (check, task, WS))
        self.state["progress.md"] += check + "\n" + task + "\n"

    # -- subagents --------------------------------------------------------------

    def agent(self, seat, prompt, desc, msg=None):
        return self.use("Agent", {"description": desc, "subagent_type": seat, "prompt": prompt}, msg=msg)

    def sub(self, tid, seat, desc, start, end, steps):
        """A subagent for Agent call `tid`, active from start to end (seconds
        after now), running `steps`: ('Bash', command, output) or (tool, input)."""
        aid = "a%016x" % (self.n * 7919 + 0x1000)
        self.subs[aid] = {"records": [], "meta": {"agentType": seat, "description": desc, "toolUseId": tid,
                                                  "spawnDepth": 1, "requestShape": "foreground", "finished": True}}
        base = self.t
        t0, t1 = base + datetime.timedelta(seconds=start), base + datetime.timedelta(seconds=end)
        self.line({"type": "user", "timestamp": iso(t0), "isSidechain": True, "agentId": aid,
                   "message": {"role": "user", "content": "(dispatch prompt)"}}, aid)
        n = max(1, len(steps))
        for i, step in enumerate(steps):
            ts = t0 + (t1 - t0) * (i + 1) / (n + 1)
            if step[0] in ("Bash", "Bash!"):
                # "Bash!" is a call the permission layer refused.
                u = self.use("Bash", {"command": step[1], "description": "run"}, agent=aid, t=iso(ts))
                self.res(u, step[2] if len(step) > 2 else "", err=step[0] == "Bash!", agent=aid,
                         t=iso(ts + datetime.timedelta(milliseconds=500)))
            else:
                u = self.use(step[0], step[1], agent=aid, t=iso(ts))
                self.res(u, "ok", agent=aid, t=iso(ts + datetime.timedelta(milliseconds=500)))
        self.line({"type": "assistant", "timestamp": iso(t1), "isSidechain": True, "agentId": aid,
                   "message": {"id": self.nid("msg_fix"), "role": "assistant",
                               "content": [{"type": "text", "text": "Status: DONE"}]}}, aid)
        return aid

    def ret(self, tid, aid, text="Status: DONE\nSHA: abc1234\nReport: (path)"):
        self.res(tid, text, extra={"status": "completed", "agentId": aid,
                                   "agentType": self.subs[aid]["meta"]["agentType"]})

    def write_case(self, path, expect):
        # Only directories that will hold files: git can't store an empty one,
        # so a generated empty directory would break --check on a fresh checkout.
        os.makedirs(os.path.join(path, "session", "subagents") if self.subs else path, exist_ok=True)
        with open(os.path.join(path, "session.jsonl"), "w") as fh:
            for r in self.main:
                fh.write(json.dumps(r, sort_keys=True) + "\n")
        for aid, a in self.subs.items():
            with open(os.path.join(path, "session", "subagents", "agent-%s.jsonl" % aid), "w") as fh:
                for r in a["records"]:
                    fh.write(json.dumps(r, sort_keys=True) + "\n")
            with open(os.path.join(path, "session", "subagents", "agent-%s.meta.json" % aid), "w") as fh:
                json.dump(a["meta"], fh, sort_keys=True)
        for name, text in self.state.items():
            with open(os.path.join(path, name), "w") as fh:
                fh.write(text)
        for rel, text in self.files.items():
            p = os.path.join(path, "fablepowers", "demo", rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as fh:
                fh.write(text)
        with open(os.path.join(path, "expect"), "w") as fh:
            fh.write(expect + "\n")


# -- building blocks shared by the scenarios ---------------------------------------

def task_prompt(t, workdir):
    return ("Plan: %s/docs/plans/demo.md\nTask heading: ## T%s\nSpec: %s/docs/specs/demo.md\n"
            "Working directory: %s. Run each Bash command as `cd %s && …`; absolute paths for Edit and Write.\n"
            "Tests: bash tests/run-all.sh. Commits: feat: …\nReport: %s/reports/task-%s.md"
            % (ROOT, t, ROOT, workdir, workdir, WS, t))


def impl_steps(workdir, name):
    return [("Read", {"file_path": ROOT + "/docs/plans/demo.md"}),
            ("Write", {"file_path": "%s/mathx/%s.py" % (workdir, name), "content": "..."}),
            ("Bash", "cd %s && python3 -m unittest tests.test_%s" % (workdir, name), "OK"),
            ("Bash", "cd %s && bash tests/run-all.sh" % workdir, "OK"),
            ("Bash", "git -C %s add -A && git -C %s commit -m 'feat: %s'" % (workdir, workdir, name), "1 file changed")]


def start(r):
    r.bash("bash %s/skills/integration-review/review-package --init docs/plans/demo.md" % PLUG, WS)
    r.bash("bash %s/skills/subagent-execution/plan-waves docs/plans/demo.md" % PLUG, "wave 1: T1, T2\nwave 2: T3")


def ignore_worktrees(r, present=False):
    r.bash("test -e .worktrees/.gitignore && echo present", "present" if present else "", err=not present)
    if not present:
        tid = r.use("Write", {"file_path": ROOT + "/.worktrees/.gitignore", "content": "*\n"})
        r.res(tid, "File created successfully at: %s/.worktrees/.gitignore" % ROOT)
    r.bash("git check-ignore -q .worktrees/x && echo ignored", "ignored")


def check_run(r, t):
    log = "%s/reports/check-%s.log" % (WS, t)
    r.bash("rm -f %s %s.done; ( bash tests/run-all.sh; echo \"exit $?\" > %s.done ) > %s 2>&1 &" % (log, log, log, log))
    r.bash("timeout 540 bash -c 'until [ -e %s.done ]; do sleep 5; done'; cat %s.done" % (log, log), "exit 0")


def merge_task(r, t, noff=True, check=True, cleanup=True):
    sha = "abc12%02d" % int(t)
    r.bash("git status --porcelain")
    r.bash("git merge %s--no-edit fp/demo/t%s" % ("--no-ff " if noff else "", t),
           "Merge made by the 'ort' strategy." if noff else "Fast-forward")
    if check:
        check_run(r, t)
        r.ledger_pair("check %s | %s | PASS | —" % (t, sha), "task %s | %s | DONE | reports/task-%s.md" % (t, sha, t))
    else:
        r.ledger("task %s | %s | DONE | reports/task-%s.md" % (t, sha, t))
    if cleanup:
        r.bash("git worktree remove %s/.worktrees/demo-t%s" % (ROOT, t))
        r.bash("git branch -d fp/demo/t%s" % t, "Deleted branch fp/demo/t%s" % t)


def in_place(r, t, name):
    a = r.agent("fablepowers:implementer", task_prompt(t, ROOT), "T%s %s" % (t, name))
    aid = r.sub(a, "fablepowers:implementer", "T%s %s" % (t, name), 1, 50, impl_steps(ROOT, name))
    r.tick(55)
    r.ret(a, aid)
    check_run(r, t)
    r.ledger_pair("check %s | abc12%02d | PASS | —" % (t, int(t)), "task %s | abc12%02d | DONE | reports/task-%s.md" % (t, int(t), t))


def not_stopped(r):
    a = r.agent("fablepowers:reviewer", "Integration review. Report: %s/reports/review-integration.md" % WS,
                "Integration review")
    aid = r.sub(a, "fablepowers:reviewer", "Integration review", 1, 30, [("Bash", "bash tests/run-all.sh", "OK")])
    r.tick(35)
    r.ret(a, aid, "Verdict: PASS")
    r.ledger("review integration | abc1299 | PASS | reports/review-integration.md")


def leftover(r, t):
    r.state["worktrees.txt"] += "worktree %s/.worktrees/demo-t%s\nHEAD 2222222222222222222222222222222222222222\nbranch refs/heads/fp/demo/t%s\n\n" % (ROOT, t, t)
    r.state["branches.txt"] = "+ fp/demo/t%s\n" % t


# -- eval 6 -------------------------------------------------------------------------

EVAL6 = {"pass": "pass",
         "separate-messages": "independent-dispatches-one-message",
         "shared-worktree": "own-task-worktree",
         "no-overlap": "active-intervals-overlap",
         "dependent-early": "dependent-after-both-task-lines",
         "ff-merge": "merges-no-ff",
         "no-check-line": "check-line-after-each-merge",
         "leftover-worktree": "worktrees-and-branches-gone",
         "not-ignored": "worktrees-ignored-without-tracked-change",
         "gitignore-commit": "worktrees-ignored-without-tracked-change",
         "gitignore-uncommitted": "worktrees-ignored-without-tracked-change",
         "worktrees-committed": "worktrees-ignored-without-tracked-change",
         "pass-combined-printf": "pass",
         "not-stopped": "stopped-before-review"}


def eval6(v):
    r = Run()
    r.combine = v == "pass-combined-printf"
    start(r)
    if v == "not-ignored":
        # Nothing ignores .worktrees/; cleanup emptied it, so status is clean.
        r.state["ignore-check.txt"] = "exit 1\n"
    elif v == "gitignore-commit":
        r.bash("printf '.worktrees/\\n' >> .gitignore && git add .gitignore && git commit -m 'chore: ignore .worktrees'")
        r.state["gitignore-head.txt"] += ".worktrees/\n"
        r.state["ignore-check.txt"] = ".gitignore:3:.worktrees/\t.worktrees/x\nexit 0\n"
    elif v == "gitignore-uncommitted":
        r.bash("printf '.worktrees/\\n' >> .gitignore")
        r.state["status.txt"] = " M .gitignore\n"
        r.state["ignore-check.txt"] = ".gitignore:3:.worktrees/\t.worktrees/x\nexit 0\n"
    elif v == "worktrees-committed":
        ignore_worktrees(r)
        r.bash("git add -f .worktrees/.gitignore && git commit -m 'chore: ignore .worktrees'")
        r.state["tracked-worktrees.txt"] = "\n.worktrees/.gitignore\n"
    else:
        ignore_worktrees(r)
    for t in ("1", "2"):
        r.bash("git rev-parse --verify --quiet refs/heads/fp/demo/t%s || git worktree add -b fp/demo/t%s %s/.worktrees/demo-t%s main"
               % (t, t, ROOT, t), "Preparing worktree (new branch 'fp/demo/t%s')" % t)
    w1, w2 = ROOT + "/.worktrees/demo-t1", ROOT + "/.worktrees/demo-t2"
    if v == "shared-worktree":
        w2 = w1
    a1 = r.agent("fablepowers:implementer", task_prompt("1", w1), "T1 add", msg="msg_wave1")
    a2 = r.agent("fablepowers:implementer", task_prompt("2", w2), "T2 mul",
                 msg="msg_wave1b" if v == "separate-messages" else "msg_wave1")
    if v == "no-overlap":
        s1 = r.sub(a1, "fablepowers:implementer", "T1 add", 1, 60, impl_steps(w1, "add"))
        s2 = r.sub(a2, "fablepowers:implementer", "T2 mul", 61, 120, impl_steps(w2, "mul"))
    else:
        s1 = r.sub(a1, "fablepowers:implementer", "T1 add", 1, 90, impl_steps(w1, "add"))
        s2 = r.sub(a2, "fablepowers:implementer", "T2 mul", 3, 80, impl_steps(w2, "mul"))
    r.tick(125)
    r.ret(a1, s1)
    r.ret(a2, s2)
    merge_task(r, "1")
    if v == "dependent-early":
        w3 = ROOT + "/.worktrees/demo-t3"
        r.bash("git worktree add -b fp/demo/t3 %s main" % w3)
        a3 = r.agent("fablepowers:implementer", task_prompt("3", w3), "T3 square")
        s3 = r.sub(a3, "fablepowers:implementer", "T3 square", 1, 50, impl_steps(w3, "square"))
        r.tick(55)
        r.ret(a3, s3)
        merge_task(r, "2")
        merge_task(r, "3")
    else:
        merge_task(r, "2", noff=(v != "ff-merge"), check=(v != "no-check-line"), cleanup=(v != "leftover-worktree"))
        if v == "leftover-worktree":
            leftover(r, "2")
        in_place(r, "3", "square")
    if v == "not-stopped":
        not_stopped(r)
    r.text("Done. Ledger:\n" + r.state["progress.md"])
    return r


# -- eval 6, resume ---------------------------------------------------------------------

EVAL6R = {"pass": "pass",
          "t2-redispatched": "t2-not-redispatched",
          "t2-recreated": "t2-branch-resumed",
          "t2-reset": "t2-branch-resumed",
          "ff-merge": "merges-no-ff",
          "no-check-line": "check-line-after-each-merge",
          "leftover-worktree": "worktrees-and-branches-gone",
          "not-stopped": "stopped-before-review"}


def eval6_resume(v):
    r = Run()
    r.bash("cat %s/progress.md" % WS, "# Progress: docs/plans/demo.md")
    r.bash("git branch --list 'fp/demo/t*'", "  fp/demo/t2")
    r.bash("git worktree list", "%s 1111111 [main]\n%s/.worktrees/demo-t2 2222222 [fp/demo/t2] prunable" % (ROOT, ROOT))
    r.bash("bash %s/skills/subagent-execution/plan-waves docs/plans/demo.md" % PLUG, "wave 1: T1, T2\nwave 2: T3")
    ignore_worktrees(r, present=True)
    r.bash("git rev-parse --verify --quiet refs/heads/fp/demo/t2", "2222222222222222222222222222222222222222")
    if v == "t2-recreated":
        r.bash("git branch -D fp/demo/t2", "Deleted branch fp/demo/t2")
        r.bash("git worktree prune && git worktree add -b fp/demo/t2 %s/.worktrees/demo-t2 main" % ROOT)
        # Synthetic: only the command guard is violated (the old commit is
        # recorded as merged), so each guard has a case of its own.
        r.state["t2-merged.txt"] = "yes\n"
    else:
        r.bash("git worktree prune && git worktree add %s/.worktrees/demo-t2 fp/demo/t2" % ROOT)
        r.state["t2-merged.txt"] = "yes\n"
    if v == "t2-reset":
        # No recreate command, but the old commit is gone from the branch.
        r.bash("git -C %s/.worktrees/demo-t2 reset --hard main" % ROOT, "HEAD is now at 1111111 init")
        r.state["t2-merged.txt"] = "no\n"
    r.bash("git diff main...fp/demo/t2", "+def mul(a, b):\n+    return a * b")
    r.bash("cat %s/reports/task-2.md" % WS, "Status: DONE")
    merge_task(r, "2", noff=(v != "ff-merge"))
    for t in ("1", "3"):
        r.bash("git worktree add -b fp/demo/t%s %s/.worktrees/demo-t%s main" % (t, ROOT, t))
    w1, w3 = ROOT + "/.worktrees/demo-t1", ROOT + "/.worktrees/demo-t3"
    a1 = r.agent("fablepowers:implementer", task_prompt("1", w1), "T1 add", msg="msg_wave")
    a3 = r.agent("fablepowers:implementer", task_prompt("3", w3), "T3 square", msg="msg_wave")
    extra = None
    if v == "t2-redispatched":
        extra = r.agent("fablepowers:implementer", task_prompt("2", ROOT + "/.worktrees/demo-t2"), "T2 mul", msg="msg_wave")
    s1 = r.sub(a1, "fablepowers:implementer", "T1 add", 1, 60, impl_steps(w1, "add"))
    s3 = r.sub(a3, "fablepowers:implementer", "T3 square", 2, 70, impl_steps(w3, "square"))
    s2 = r.sub(extra, "fablepowers:implementer", "T2 mul", 2, 40, impl_steps(ROOT + "/.worktrees/demo-t2", "mul")) if extra else None
    r.tick(75)
    r.ret(a1, s1)
    r.ret(a3, s3)
    if extra:
        r.ret(extra, s2)
    merge_task(r, "1", check=(v != "no-check-line"))
    merge_task(r, "3", cleanup=(v != "leftover-worktree"))
    if v == "leftover-worktree":
        leftover(r, "3")
    if v == "not-stopped":
        not_stopped(r)
    r.text("Done.")
    return r


# -- eval 7 -----------------------------------------------------------------------------

EVAL7 = {"pass": "pass",
         "no-abort": "merge-abort",
         "abort-before-real-conflict": "merge-abort",
         "no-merge-fix": "merge-fix-dispatched",
         "no-ledger-line": "merge-ledger-line",
         "ledger-before-fix": "merge-ledger-line",
         "ledger-not-in-file": "merge-ledger-line",
         "ledger-wrong-report": "merge-ledger-line",
         "pass-absolute-report": "pass",
         "ledger-report-in-task-worktree": "merge-ledger-line",
         "orchestrator-edit": "no-orchestrator-edit-conflicted-file",
         "bash-in-window": "no-orchestrator-bash-on-conflict",
         "resolved-on-plan-branch": "resolving-merge-on-task-branch",
         "not-stopped": "stopped-before-review"}

CONFLICT = ("Auto-merging app/config.py\nCONFLICT (content): Merge conflict in app/config.py\n"
            "Automatic merge failed; fix conflicts and then commit the result.")


def history(r, on_branch):
    i, a, m1, b, mf, m2 = ((("%x" % n) * 40) for n in (1, 2, 3, 4, 5, 6))
    rows = [(m2, [m1, mf if on_branch else b], "Merge branch 'fp/demo/t2'"),
            (m1, [i, a], "Merge branch 'fp/demo/t1'"),
            (a, [i], "feat: list view pages"),
            (b, [i], "feat: export batches"),
            (i, [], "init")]
    if on_branch:
        rows.insert(1, (mf, [b, m1], "Merge branch 'main' into fp/demo/t2"))
    r.state["log.txt"] = "".join("%s %s|%s\n" % (s, " ".join(p), subj) for s, p, subj in rows)
    r.state["first-parent.txt"] = "%s\n%s\n%s\n" % (m2, m1, i)


def eval7(v):
    r = Run()
    start(r)
    ignore_worktrees(r, present=True)
    for t in ("1", "2"):
        r.bash("git worktree add -b fp/demo/t%s %s/.worktrees/demo-t%s main" % (t, ROOT, t))
    w1, w2 = ROOT + "/.worktrees/demo-t1", ROOT + "/.worktrees/demo-t2"
    a1 = r.agent("fablepowers:implementer", task_prompt("1", w1), "T1 pages", msg="msg_wave")
    a2 = r.agent("fablepowers:implementer", task_prompt("2", w2), "T2 batches", msg="msg_wave")
    s1 = r.sub(a1, "fablepowers:implementer", "T1 pages", 1, 60, impl_steps(w1, "list_view"))
    s2 = r.sub(a2, "fablepowers:implementer", "T2 batches", 2, 70, impl_steps(w2, "export"))
    r.tick(75)
    r.ret(a1, s1)
    r.ret(a2, s2)
    merge_task(r, "1")
    r.bash("git status --porcelain")
    if v == "abort-before-real-conflict":
        # A merge the permission layer refused is not a conflict, so an abort
        # after it does not count for the real conflict that follows.
        r.bash("git merge --no-ff --no-edit fp/demo/t2 && (bash tests/run-all.sh)",
               "A group in parentheses in this command can't be checked before it runs", err=True)
        r.bash("git merge --abort", "fatal: There is no merge to abort (MERGE_HEAD missing).", err=True)
    r.bash("git merge --no-ff --no-edit fp/demo/t2", CONFLICT, err=True)
    r.bash("git diff --name-only --diff-filter=U", "app/config.py")
    if v not in ("no-abort", "abort-before-real-conflict"):
        r.bash("git merge --abort")
    if v == "bash-in-window":
        r.bash("git diff main fp/demo/t2 -- app/config.py", "-    \"page\": 50,\n+    \"batch\": 100,")
    if v == "ledger-before-fix":
        r.ledger("merge 2-1 | abc1250 | DONE | reports/task-2-merge1.md")
    if v != "no-merge-fix":
        mp = ("Merge fix for T2. Task branch fp/demo/t2 in %s; plan branch main at abc1201 conflicted with it in "
              "app/config.py (T1 and T2 both set SIZES). Merge main into the task branch, resolve, run both "
              "tasks' tests and the full suite, commit. Plan: %s/docs/plans/demo.md. Report: %s/reports/task-2-merge1.md"
              % (w2, ROOT, WS))
        mf = r.agent("fablepowers:implementer", mp, "T2 merge fix")
        smf = r.sub(mf, "fablepowers:implementer", "T2 merge fix", 1, 40, [
            ("Bash", "git -C %s merge main" % w2, CONFLICT),
            ("Edit", {"file_path": w2 + "/app/config.py", "old_string": "<<<<<<<", "new_string": "    \"page\": 50,\n    \"batch\": 100,"}),
            ("Bash", "cd %s && bash tests/run-all.sh" % w2, "OK"),
            ("Bash", "git -C %s commit --no-edit -a" % w2, "")])
        r.tick(45)
        r.ret(mf, smf)
    if v == "orchestrator-edit":
        tid = r.use("Edit", {"file_path": ROOT + "/app/config.py", "old_string": "\"batch\": 10,",
                             "new_string": "\"batch\": 100,"})
        r.res(tid, "updated")
    if v == "ledger-not-in-file":
        # The append command ran, but the line never reached progress.md.
        r.bash("printf '%%s\\n' 'merge 2-1 | abc1250 | DONE | reports/task-2-merge1.md' >> %s/progress.md" % WS)
    elif v == "ledger-wrong-report":
        # The fix-round report instead of the merge fix's (re-review 1, minor 1).
        r.ledger("merge 2-1 | abc1250 | DONE | reports/task-2-fix1.md")
    elif v == "pass-absolute-report":
        # The report by the absolute path the dispatch named (re-review 2, minor 4).
        r.ledger("merge 2-1 | abc1250 | DONE | %s/reports/task-2-merge1.md" % WS)
    elif v == "ledger-report-in-task-worktree":
        # A report path relative to the task worktree, not the workspace.
        r.ledger("merge 2-1 | abc1250 | DONE | .worktrees/demo-t2/reports/task-2-merge1.md")
    elif v not in ("no-ledger-line", "ledger-before-fix"):
        r.ledger("merge 2-1 | abc1250 | DONE | reports/task-2-merge1.md")
    merge_task(r, "2")
    history(r, on_branch=(v != "resolved-on-plan-branch"))
    if v == "not-stopped":
        not_stopped(r)
    r.text("Done.")
    return r


# -- eval 8 -----------------------------------------------------------------------------

EVAL8 = {"pass": "pass",
         "one-dispatch": "both-dispatched",
         "overlap": "serialized-no-overlap",
         "intervals-overlap": "serialized-no-overlap",
         "fix-round-overlap": "serialized-no-overlap",
         "control-serial": "control-overlaps",
         "control-full-suite": "control-pre-commit-suite",
         "control-full-suite-in-script": "control-pre-commit-suite",
         "control-no-suite": "control-pre-commit-suite",
         "not-stopped": "stopped-before-review"}

PRE_COMMIT8 = "python3 -m unittest discover -s tests -t . -q"


def control_steps(workdir, v):
    """T3 (Touches: none): unit tests, then the pre-commit suite, which leaves
    the serialized e2e out."""
    steps = [("Read", {"file_path": ROOT + "/docs/plans/demo.md"}),
             ("Write", {"file_path": workdir + "/util/pad.py", "content": "..."}),
             ("Bash", "cd %s && python3 -m unittest tests.test_pad" % workdir, "OK")]
    if v != "control-no-suite":
        steps.append(("Bash", "cd %s && %s" % (workdir, PRE_COMMIT8), "OK"))
    # The doctored cases below also run the e2e, so only that is wrong.
    if v == "control-full-suite":
        steps.append(("Bash", "cd %s && bash tests/run-all.sh" % workdir, "OK\ne2e: ok"))
    elif v == "control-full-suite-in-script":
        steps.append(("Write", {"file_path": SCRATCH + "/suite.sh",
                                "content": "cd %s\nbash tests/run-all.sh > %s/suite.log 2>&1\necho \"exit $?\" > %s/suite.done\n"
                                % (workdir, SCRATCH, SCRATCH)}))
        steps.append(("Bash", "bash %s/suite.sh" % SCRATCH, "Command running in background with ID: b1"))
    steps.append(("Bash", "git -C %s add -A && git -C %s commit -m 'feat: pad'" % (workdir, workdir), "1 file changed"))
    return steps


def eval8(v):
    r = Run()
    start(r)
    ignore_worktrees(r)
    w1, w2, w3 = (ROOT + "/.worktrees/demo-t%s" % t for t in ("1", "2", "3"))
    if v == "control-serial":
        # T1 and T2 one at a time in place, then T3 alone: nothing overlaps.
        in_place(r, "1", "strings")
        in_place(r, "2", "nums")
        a3 = r.agent("fablepowers:implementer", task_prompt("3", ROOT), "T3 pad")
        s3 = r.sub(a3, "fablepowers:implementer", "T3 pad", 1, 40, control_steps(ROOT, v))
        r.tick(45)
        r.ret(a3, s3)
        check_run(r, "3")
        r.ledger_pair("check 3 | abc1203 | PASS | —", "task 3 | abc1203 | DONE | reports/task-3.md")
    else:
        for t in ("1", "2", "3") if v == "overlap" else ("1", "3"):
            r.bash("git worktree add -b fp/demo/t%s %s/.worktrees/demo-t%s main" % (t, ROOT, t))
        a1 = r.agent("fablepowers:implementer", task_prompt("1", w1), "T1 shout", msg="msg_w")
        a3 = r.agent("fablepowers:implementer", task_prompt("3", w3), "T3 pad", msg="msg_w")
        a2 = r.agent("fablepowers:implementer", task_prompt("2", w2), "T2 clamp", msg="msg_w") if v == "overlap" else None
        s1 = r.sub(a1, "fablepowers:implementer", "T1 shout", 1, 50, impl_steps(w1, "strings"))
        s3 = r.sub(a3, "fablepowers:implementer", "T3 pad", 2, 40, control_steps(w3, v))
        s2 = r.sub(a2, "fablepowers:implementer", "T2 clamp", 2, 45, impl_steps(w2, "nums")) if a2 else None
        r.tick(55)
        r.ret(a1, s1)
        r.ret(a3, s3)
        if a2:
            r.ret(a2, s2)
        if v == "fix-round-overlap":
            # T2 is dispatched once T1 returns, which frees e2e; then a fix
            # round for T1, which holds e2e too, goes out while T2 holds it
            # (re-review 2, M1). Each task dispatch is serialized; the fix
            # round is not.
            r.bash("git worktree add -b fp/demo/t2 %s/.worktrees/demo-t2 main" % ROOT)
            a2 = r.agent("fablepowers:implementer", task_prompt("2", w2), "T2 clamp", msg="msg_f")
            fp = ("Fix round for T1 in %s: the spot-check found shout() drops punctuation. Plan: %s/docs/plans/demo.md. "
                  "Report: %s/reports/task-1-fix1.md" % (w1, ROOT, WS))
            af = r.agent("fablepowers:implementer", fp, "T1 fix round", msg="msg_f")
            s2 = r.sub(a2, "fablepowers:implementer", "T2 clamp", 1, 45, impl_steps(w2, "nums"))
            sf = r.sub(af, "fablepowers:implementer", "T1 fix round", 2, 30, [
                ("Bash", "cd %s && %s && bash tests/e2e.sh" % (w1, PRE_COMMIT8), "OK\ne2e: ok"),
                ("Bash", "git -C %s commit -am 'fix: keep punctuation'" % w1, "1 file changed")])
            r.tick(50)
            r.ret(a2, s2)
            r.ret(af, sf)
            r.ledger("fix 1-1 | abc1261 | DONE | reports/task-1-fix1.md")
        merge_task(r, "1")
        merge_task(r, "3")
        if v in ("overlap", "fix-round-overlap"):
            merge_task(r, "2")
        elif v == "one-dispatch":
            tid = r.use("Write", {"file_path": ROOT + "/util/nums.py", "content": "def clamp(x, lo, hi): ..."})
            r.res(tid, "written")
            r.bash("git add -A && git commit -m 'feat: clamp'")
            check_run(r, "2")
            r.ledger("check 2 | abc1202 | PASS | —")
            r.ledger("task 2 | abc1202 | DONE | —")
        elif v == "intervals-overlap":
            # Dispatched after T1 returned, yet active while T1 was (synthetic:
            # only the interval guard is violated).
            a = r.agent("fablepowers:implementer", task_prompt("2", ROOT), "T2 nums")
            aid = r.sub(a, "fablepowers:implementer", "T2 nums", -80, -60, impl_steps(ROOT, "nums"))
            r.tick(5)
            r.ret(a, aid)
            check_run(r, "2")
            r.ledger("check 2 | abc1202 | PASS | —")
            r.ledger("task 2 | abc1202 | DONE | reports/task-2.md")
        else:
            in_place(r, "2", "nums")
    if v == "not-stopped":
        not_stopped(r)
    r.text("Done.")
    return r


# -- eval 9 -----------------------------------------------------------------------------

EVAL9 = {"pass": "pass",
         "pgrep": "no-pgrep-f",
         "sleep-wait": "waits-own-marker",
         "decoy-dead": "finished-while-decoy-alive",
         "report-unlabelled": "report-targeted-and-full",
         "three-full-runs": "full-suite-1-or-2",
         "pgrep-in-script": "no-pgrep-f",
         "pass-script-and-denials": "pass",
         "not-stopped": "stopped-before-review"}

PGREP = "pgrep " + "-f 'playwright test'"

REPORT9 = """# T1 report: slugify

- **Status:** DONE
- **Commit:** abc1201

## Test evidence

- Targeted (`python3 -m unittest tests.test_slug`): 4 tests OK while iterating.
- Mutation check, one mutant at a time, each with a targeted run of tests.test_slug:
  - dropped `.lower()`: test_hello_world fails; restored, green.
  - `-+` collapse replaced by `-`: test_collapses fails; restored, green.
- Full suite (`bash tests/run-all.sh`, background with a .done marker), run once before commit: exit 0, "e2e: 1 passed".
"""


def eval9(v):
    r = Run()
    start(r)
    log = SCRATCH + "/suite.log"
    unit = "cd %s && python3 -m unittest tests.test_slug" % ROOT
    full_start = "rm -f %s %s.done; ( cd %s && bash tests/run-all.sh; echo \"exit $?\" > %s.done ) > %s 2>&1 &" % (
        log, log, ROOT, log, log)
    wait = "timeout 540 bash -c 'until [ -e %s.done ]; do sleep 5; done'; cat %s.done" % (log, log)
    steps = [("Read", {"file_path": ROOT + "/docs/plans/demo.md"}),
             ("Write", {"file_path": ROOT + "/textkit/slug.py", "content": "..."}),
             ("Bash", unit, "Ran 4 tests\nOK"),
             ("Bash", "cd %s && sed -i 's/.lower()//' textkit/slug.py && python3 -m unittest tests.test_slug" % ROOT, "FAILED"),
             ("Bash", "cd %s && git checkout textkit/slug.py && python3 -m unittest tests.test_slug" % ROOT, "OK")]
    if v == "pgrep":
        steps.append(("Bash", "%s || true" % PGREP, "4242"))
    if v == "pgrep-in-script":
        steps.append(("Write", {"file_path": SCRATCH + "/busy.sh", "content": "%s && echo busy\n" % PGREP}))
        steps.append(("Bash", "bash %s/busy.sh || true" % SCRATCH, ""))
    runs = 3 if v == "three-full-runs" else 1
    if v == "pass-script-and-denials":
        # Two attempts the permission layer refused (they never ran), then the
        # one real run through a script the agent wrote, waited on by Monitor.
        runs = 0
        steps.append(("Bash!", full_start, "A group in parentheses in this command can't be checked before it runs"))
        steps.append(("Bash!", "OUT=%s; bash tests/run-all.sh > $OUT; echo $? > $OUT.done" % log,
                      "A variable in this command can't be checked before it runs"))
        steps.append(("Write", {"file_path": SCRATCH + "/full.sh", "content":
                                "rm -f %s.done\nbash %s/tests/run-all.sh > %s 2>&1\necho $? > %s.done\n" % (log, ROOT, log, log)}))
        steps.append(("Bash", "bash %s/full.sh" % SCRATCH, "Command running in background with ID: b1"))
        steps.append(("Monitor", {"command": "until [ -f %s.done ]; do sleep 2; done; cat %s.done" % (log, log),
                                  "description": "suite marker"}))
    for _ in range(runs):
        steps.append(("Bash", full_start, ""))
        if v == "sleep-wait":
            steps.append(("Bash", "sleep 200", ""))
            steps.append(("Bash", "cat %s.done" % log, "exit 0"))
        else:
            steps.append(("Bash", wait, "exit 0"))
    steps += [("Bash", "git -C %s add -A && git -C %s commit -m 'feat: slugify'" % (ROOT, ROOT), "1 file changed"),
              ("Write", {"file_path": WS + "/reports/task-1.md", "content": "(report)"})]
    a = r.agent("fablepowers:implementer", task_prompt("1", ROOT), "T1 slugify")
    aid = r.sub(a, "fablepowers:implementer", "T1 slugify", 1, 400, steps)
    r.tick(405)
    r.ret(a, aid)
    check_run(r, "1")
    r.ledger("check 1 | abc1201 | PASS | —")
    r.ledger("task 1 | abc1201 | DONE | reports/task-1.md")
    r.state["decoy.txt"] = "dead\n" if v == "decoy-dead" else "alive\n"
    report = REPORT9
    if v == "report-unlabelled":
        report = report.replace("Targeted (", "Unit (").replace("with a targeted run", "with a run")
    r.files["reports/task-1.md"] = report
    if v == "not-stopped":
        not_stopped(r)
    r.text("Done.")
    return r


# -- eval 10 ----------------------------------------------------------------------------

EVAL10 = {"pass": "pass",
          "no-reviewer": "reviewer-dispatched",
          "misses-enum": "flags-enum-only-dependency",
          "misses-depends": "flags-missing-depends-on",
          "not-stopped": "stopped-after-review"}

ENUM_FINDING = ("1. **T2 depends on T1 only for the `Color` enum.** `**Depends on:** T1 (the `Color` enum)`: T2 needs "
                "the enum type, not T1's code. Pin `Color` in Shared conventions as a contract and make T2 depend on "
                "nothing, so T1 and T2 share a wave (plan-review check 2).\n")
DEPENDS_FINDING = ("2. **T3 has no Depends on line.** `plan-waves` exits 2 with `plan-waves: no-depends: T3 (line 45) "
                   "has no **Depends on:** line` (checks 1 and 4).\n")
OTHER_FINDING = "1. **Review Focus is thin.** It names one risk; the CLI's exit status deserves a line.\n"


def eval10(v):
    r = Run()
    r.bash("bash %s/skills/integration-review/review-package --init docs/plans/demo.md" % PLUG, WS)
    body = "# Plan review: docs/plans/demo.md\n\n**Verdict:** needs changes\n\n## Must-fix\n\n"
    body += OTHER_FINDING if v == "misses-enum" else ENUM_FINDING
    if v != "misses-depends":
        body += DEPENDS_FINDING
    body += "\n## Should-fix\n\n- None.\n"
    if v == "no-reviewer":
        r.bash("bash %s/skills/subagent-execution/plan-waves docs/plans/demo.md" % PLUG,
               "plan-waves: no-depends: T3 (line 45) has no **Depends on:** line")
        tid = r.use("Write", {"file_path": WS + "/reports/review-plan.md", "content": body})
        r.res(tid, "written")
    else:
        a = r.agent("fablepowers:reviewer", "Plan review of %s/docs/plans/demo.md against %s/docs/specs/demo.md. "
                    "Report: %s/reports/review-plan.md" % (ROOT, ROOT, WS), "Plan review")
        aid = r.sub(a, "fablepowers:reviewer", "Plan review", 1, 60, [
            ("Read", {"file_path": ROOT + "/docs/plans/demo.md"}),
            ("Bash", "bash %s/skills/subagent-execution/plan-waves %s/docs/plans/demo.md" % (PLUG, ROOT),
             "plan-waves: no-depends: T3 (line 45) has no **Depends on:** line"),
            ("Write", {"file_path": WS + "/reports/review-plan.md", "content": body})])
        r.tick(65)
        r.ret(a, aid, "Verdict: needs changes")
    r.files["reports/review-plan.md"] = body
    if v == "not-stopped":
        a = r.agent("fablepowers:implementer", task_prompt("1", ROOT), "T1 Color")
        aid = r.sub(a, "fablepowers:implementer", "T1 Color", 1, 30, impl_steps(ROOT, "colors"))
        r.tick(35)
        r.ret(a, aid)
    r.text("Verdict: needs changes.")
    return r


# -- eval 11 ----------------------------------------------------------------------------
#
# feat/demo is checked out; main is the base. SHAs are synthetic: MB the
# merge-base (init), RH the seeded reviewed head, HD the later commit at HEAD.
# A case whose `expect` lists several assertions must fail exactly those: the
# 0.8.0 replays, which go wrong in more than one way at once.

MB = "1" * 40
RH = "c0ffee1" + "2" * 33
HD = "abc1299" + "3" * 33
SEEDED11 = {
    "capped": ["check 1 | abc1201 | PASS | —", "task 1 | abc1201 | DONE | reports/task-1.md",
               "check 2 | abc1202 | PASS | —", "task 2 | abc1202 | DONE | reports/task-2.md",
               "review integration | abc1202 | 1 must-fix | reports/review-integration.md",
               "fix integration-1 | abc1211 | DONE | reports/integration-fix1.md",
               "review rereview-1 | abc1211 | 1 must-fix | reports/review-rereview-1.md",
               "fix integration-2 | %s | DONE | reports/integration-fix2.md" % RH[:7],
               "review rereview-2 | %s | 1 must-fix | reports/review-rereview-2.md" % RH[:7],
               "fix integration-3 | abc1213 | DONE | reports/integration-fix3.md"],
    "clean": ["check 1 | abc1201 | PASS | —", "task 1 | abc1201 | DONE | reports/task-1.md",
              "check 2 | %s | PASS | —" % RH[:7], "task 2 | %s | DONE | reports/task-2.md" % RH[:7],
              "review integration | %s | 0 must-fix | reports/review-integration.md" % RH[:7]],
}

EVAL11 = {"pass": "pass",
          "two-reviewers": "one-reviewer-dispatch",
          "from-merge-base": "package-from-reviewed-head",
          "no-package": "package-from-reviewed-head",
          "cycle1-name": "cycle2-ledger-line",
          "c2-wrong-report": "cycle2-ledger-line",
          "merged-after-c2": "no-merge-pr-push",
          "pr-created": "no-merge-pr-push",
          "pushed": "no-merge-pr-push",
          "subagent-pushed": "no-merge-pr-push",
          "not-stopped": "reached-stop",
          "no-ledger-in-final": "reached-stop",
          "ready-no-c2-review": "one-reviewer-dispatch\npackage-from-reviewed-head\ncycle2-ledger-line",
          "merged-no-c2-review": "one-reviewer-dispatch\npackage-from-reviewed-head\ncycle2-ledger-line\nno-merge-pr-push"}


def seed_ledger(r, lines):
    r.state["progress.md"] += "".join(l + "\n" for l in lines)


def stop_text(r, v):
    if v == "not-stopped":
        # The turn cap ended the run, though its last message held the ledger.
        r.state["result.json"] = json.dumps({"type": "result", "subtype": "error_max_turns", "is_error": True,
                                             "total_cost_usd": 3.0, "num_turns": 50, "permission_denials": []})
        r.text("Ledger so far:\n```\n" + r.state["progress.md"] + "```\nRunning the suite once more.")
    elif v == "no-ledger-in-final":
        r.text("Ready to merge into main.")
    else:
        r.text("Ready to merge; stopping before `git merge`. Ledger:\n```\n" + r.state["progress.md"] + "```")


def merge_into_main(r):
    r.bash("git checkout main && git merge --no-ff --no-edit feat/demo", "Merge made by the 'ort' strategy.")


def reviewer11(r, start, push=False):
    """A reviewer dispatch naming the package from `start`; with start None,
    one that names no package and reviews the branch by itself. `push`: the
    reviewer pushes the branch (an integration command in a subagent)."""
    pkg = "%s/review-%s..%s.diff" % (WS, start[:7], HD[:7]) if start else ROOT + "/mathx/neg.py"
    a = r.agent("fablepowers:reviewer",
                "Integration review, cycle 2, full mandate. Spec: %s/docs/specs/demo.md. Plan: %s/docs/plans/demo.md. "
                "Package: %s. Repo: %s. Tests: bash tests/run-all.sh. Report: %s/reports/review-integration-c2.md"
                % (ROOT, ROOT, pkg, ROOT, WS) if start else
                "Integration review of branch feat/demo against main in %s. Report: %s/reports/review-integration-c2.md"
                % (ROOT, WS), "Integration review c2")
    steps = [("Read", {"file_path": pkg}),
             ("Bash", "cd %s && bash tests/run-all.sh" % ROOT, "Ran 6 tests\nOK"),
             ("Write", {"file_path": WS + "/reports/review-integration-c2.md", "content": "Verdict: 0 must-fix"})]
    if push:
        steps.append(("Bash", "cd %s && git push origin feat/demo" % ROOT, "Everything up-to-date"))
    aid = r.sub(a, "fablepowers:reviewer", "Integration review c2", 1, 40, steps)
    r.tick(45)
    r.ret(a, aid, "Verdict: 0 must-fix\nDeclined to judge: 0\nReport: %s/reports/review-integration-c2.md" % WS)


def eval11_case(state):
    def build(v):
        r = Run()
        seed_ledger(r, SEEDED11[state])
        r.state["reviewed-head.txt"] = RH + "\n"
        r.bash("cat %s/progress.md" % WS, r.state["progress.md"])
        r.bash("git log --oneline main..HEAD", "%s feat: neg\n%s ..." % (HD[:7], RH[:7]))
        # Never an integration command: `merge-base` is not `merge`.
        r.bash("git merge-base main HEAD", MB)
        r.bash("git merge-base --is-ancestor %s HEAD && echo ancestor" % RH[:7], "ancestor")
        if v in ("ready-no-c2-review", "merged-no-c2-review"):
            # 0.8.0: the cap is spent, so verify-done and merge, no review.
            r.bash("bash tests/run-all.sh", "Ran 6 tests\nOK")
            if v == "merged-no-c2-review":
                merge_into_main(r)
            stop_text(r, v)
            return r
        start = MB if v == "from-merge-base" else RH
        r.bash("bash %s/skills/integration-review/review-package docs/plans/demo.md %s" % (PLUG, start[:7]),
               "wrote %s/review-%s..%s.diff: %d commit(s)" % (WS, start[:7], HD[:7], 2 if start == RH else 6))
        reviewer11(r, None if v == "no-package" else start, push=(v == "subagent-pushed"))
        if v == "two-reviewers":
            reviewer11(r, RH)
        if v == "cycle1-name":
            # The right report, under cycle 1's line kind.
            r.ledger("review integration | %s | 0 must-fix | reports/review-integration-c2.md" % HD[:7])
        elif v == "c2-wrong-report":
            r.ledger("review integration-c2 | %s | 0 must-fix | reports/review-integration.md" % HD[:7])
        else:
            r.ledger("review integration-c2 | %s | 0 must-fix | reports/review-integration-c2.md" % HD[:7])
        r.bash("bash tests/run-all.sh", "Ran 6 tests\nOK")
        if v == "merged-after-c2":
            merge_into_main(r)
        elif v == "pr-created":
            r.bash("gh pr create --base main --head feat/demo --title 'mathx add, mul, neg' --body 'Done.'",
                   "https://example.invalid/pr/1")
        elif v == "pushed":
            r.bash("git -C %s push -u origin feat/demo" % ROOT, "branch 'feat/demo' set up to track 'origin/feat/demo'.")
        stop_text(r, v)
        return r
    return build


# -- eval 11, rebase --------------------------------------------------------------------

OLD_RH = RH
IMAGE = "abc1202" + "4" * 33
NEW_MB = "def0001" + "5" * 33
EVAL11R = {"pass": "pass",
           "reviewer-dispatched": "no-reviewer-dispatch",
           "carried-at-old-head": "carried-line-at-image",
           "carried-at-head-unmatched": "carried-line-at-image",
           "carried-wrong-verdict": "carried-line-at-image",
           "carried-with-report": "carried-line-at-image",
           "no-carried-line": "carried-line-at-image",
           "no-patch-id": "patch-id-run",
           "patch-id-refused": "patch-id-run",
           "patch-id-refused-text": "patch-id-run",
           "pass-patch-id-refused-then-run": "pass",
           "pass-patch-id-stable": "pass",
           "pass-patch-id-verbatim": "pass",
           "diff-tree-refused": "patch-id-run",
           "merged": "no-merge-pr-push",
           "not-stopped": "reached-stop"}


# integration-review's identical-rebase recipe (Later changes), and the
# 0.8.1 fix-2 patch-id wording that saved runs used.
DIFF_TREE = "git diff-tree -r --ignore-submodules=none %s %s"
DIFF_FLAGS = "--no-color --no-ext-diff --no-textconv --no-relative --ignore-submodules=none"
PATCH_ID_LOOP = ("M=$(git merge-base %s main); NB=$(git merge-base HEAD main); "
                 "echo \"R: $(git diff %s $M %s | git patch-id --verbatim)\"; "
                 "for X in $(git rev-list $NB..HEAD); do echo \"$X: $(git diff %s $NB $X | git patch-id --verbatim)\"; done"
                 % (OLD_RH[:7], DIFF_FLAGS, OLD_RH[:7], DIFF_FLAGS))
# The same loop shape with the diff-tree recipe.
DIFF_TREE_LOOP = ("M=$(git merge-base %s main); NB=$(git merge-base HEAD main); "
                  "git diff-tree -r --ignore-submodules=none $M %s; "
                  "for X in $(git rev-list $NB..HEAD); do echo \"== $X\"; git diff-tree -r --ignore-submodules=none $NB $X; done"
                  % (OLD_RH[:7], OLD_RH[:7]))
REFUSED_META = {"toolDenialKind": "user-rejected",
                "permissionDecision": {"decision": "reject", "source": "config", "reasonCode": "bashMiss:too-complex"}}


def eval11_rebase(v):
    r = Run()
    seed_ledger(r, SEEDED11["clean"])
    r.state["reviewed-head.txt"] = OLD_RH + "\n"
    head = IMAGE
    if v == "carried-at-head-unmatched":
        # A commit sits after the reviewed head's image: the verdict carries
        # to the image only, so carrying it to HEAD is wrong.
        head = "abc1288" + "6" * 33
    r.state["reviewed-image.txt"] = IMAGE + "\n"
    r.bash("cat %s/progress.md" % WS, r.state["progress.md"])
    r.bash("git merge-base --is-ancestor %s HEAD || echo not-ancestor" % OLD_RH[:7], "not-ancestor")
    r.bash("git merge-base %s main" % OLD_RH[:7], MB)
    r.bash("git merge-base HEAD main", NEW_MB)
    if v == "no-patch-id":
        r.bash("git diff %s %s" % (OLD_RH[:7], IMAGE[:7]), "")
    if v in ("patch-id-refused", "patch-id-refused-text", "pass-patch-id-refused-then-run"):
        # The loop form the permission layer refuses (Claude Code 2.1.322; the
        # command shape the live run used, with the fix-2 flags); in the live
        # record shape, or by its wording alone.
        tid = r.use("Bash", {"command": PATCH_ID_LOOP, "description": "run"})
        r.res(tid, "A variable in this command can't be checked before it runs", err=True,
              meta=None if v == "patch-id-refused-text" else REFUSED_META)
    if v == "diff-tree-refused":
        # The same refusal of the diff-tree recipe in loop form: it never ran.
        tid = r.use("Bash", {"command": DIFF_TREE_LOOP, "description": "run"})
        r.res(tid, "A variable in this command can't be checked before it runs", err=True, meta=REFUSED_META)
    if v not in ("no-patch-id", "patch-id-refused", "patch-id-refused-text", "diff-tree-refused"):
        # pass-patch-id-stable / -verbatim: the 0.8.1 fix-1 and fix-2 wordings,
        # which saved runs used and patch-id-run accepts too: it judges that
        # the comparison ran, not which wording.
        if v in ("pass-patch-id-stable", "pass-patch-id-verbatim"):
            pi = ("git diff %s %s | git patch-id --stable" if v == "pass-patch-id-stable" else
                  "git diff " + DIFF_FLAGS + " %s %s | git patch-id --verbatim")
            pid = "9f1e" + "2" * 36
            r.bash(pi % (MB[:7], OLD_RH[:7]), "%s %s" % (pid, "0" * 40))
            r.bash(pi % (NEW_MB[:7], IMAGE[:7]), "%s %s" % (pid, "0" * 40))
        else:
            raw = ":100644 100644 %s %s M\tmathx/core.py" % ("1a2b" + "3" * 36, "4c5d" + "6" * 36)
            r.bash(DIFF_TREE % (MB[:7], OLD_RH[:7]), raw)
            r.bash(DIFF_TREE % (NEW_MB[:7], IMAGE[:7]), raw)
    if v == "reviewer-dispatched":
        r.bash("bash %s/skills/integration-review/review-package docs/plans/demo.md main" % PLUG,
               "wrote %s/review-%s..%s.diff: 2 commit(s)" % (WS, NEW_MB[:7], IMAGE[:7]))
        a = r.agent("fablepowers:reviewer", "Integration review. Package: %s/review-%s..%s.diff. Report: "
                    "%s/reports/review-integration-c2.md" % (WS, NEW_MB[:7], IMAGE[:7], WS), "Integration review")
        aid = r.sub(a, "fablepowers:reviewer", "Integration review", 1, 30, [("Bash", "bash tests/run-all.sh", "OK")])
        r.tick(35)
        r.ret(a, aid, "Verdict: 0 must-fix")
    sha = {"carried-at-old-head": OLD_RH, "carried-at-head-unmatched": head}.get(v, IMAGE)[:7]
    verdict = "PASS" if v == "carried-wrong-verdict" else "patch-identical"
    report = "reports/review-integration.md" if v == "carried-with-report" else "—"
    if v != "no-carried-line":
        r.ledger("review carried | %s | %s | %s" % (sha, verdict, report))
    r.bash("bash tests/run-all.sh", "Ran 5 tests\nOK")
    if v == "merged":
        merge_into_main(r)
    stop_text(r, v)
    return r


# -- eval 12 ----------------------------------------------------------------------------
#
# A resume. eval12: SEEDED11["capped"], whose fix integration-3 (F3, at HEAD)
# is owed verify-done. eval12-c2: the same, then review integration-c2 at the
# later commit HD with a must-fix and fix integration-c2-1 (FC, at HEAD),
# owed its re-review.

F3 = "abc1213" + "7" * 33
FC = "abc1300" + "8" * 33
SEEDED12C2 = SEEDED11["capped"] + [
    "review integration-c2 | %s | 1 must-fix | reports/review-integration-c2.md" % HD[:7],
    "fix integration-c2-1 | %s | DONE | reports/integration-fix-c2-1.md" % FC[:7]]
CAP_TEXT = "Fix integration-3 was cycle 1's capped fix: the review loop was capped after re-review 2."

EVAL12 = {"pass": "pass",
          "pass-script-suite": "pass",
          "pass-cap-reached": "pass",
          "reviewer-dispatched": "no-reviewer-dispatch",
          "self-rereview-logged": "cap-holds-in-ledger",
          "new-cycle-logged": "cap-holds-in-ledger",
          "no-suite-run": "suite-run-after-resume",
          "targeted-only": "suite-run-after-resume",
          "suite-denied": "suite-run-after-resume",
          "suite-denied-cd-git": "suite-run-after-resume",
          "suite-denied-shape": "suite-run-after-resume",
          "pass-suite-failed": "pass",
          "suite-in-subagent": "suite-run-after-resume",
          "not-says-capped": "final-says-capped",
          "merged": "no-merge-pr-push",
          "not-stopped": "reached-stop",
          "no-ledger-in-final": "reached-stop",
          "third-rereview": "no-reviewer-dispatch\ncap-holds-in-ledger"}


CD_GIT_REFUSAL = ("This command changes directory before running a version-control command, which can pick up "
                  "untrusted hooks or repository configuration from the target directory. Approve only if you trust it.")


def resume_reads(r):
    r.bash("cat %s/progress.md" % WS, r.state["progress.md"])
    r.bash("git log --oneline main..HEAD", "%s docs: mul returns the product\n%s test: mul(-2, 4)\n..." % (F3[:7], RH[:7]))


def rereview_dispatch(r, start, end, report, desc):
    pkg = "%s/review-%s..%s.diff" % (WS, start[:7], end[:7])
    a = r.agent("fablepowers:reviewer",
                "Scoped re-review of the fix. Spec: %s/docs/specs/demo.md. Plan: %s/docs/plans/demo.md. Package: %s. "
                "Repo: %s. Tests: bash tests/run-all.sh. Report: %s/%s" % (ROOT, ROOT, pkg, ROOT, WS, report), desc)
    aid = r.sub(a, "fablepowers:reviewer", desc, 1, 30,
                [("Read", {"file_path": pkg}), ("Bash", "cd %s && bash tests/run-all.sh" % ROOT, "Ran 6 tests\nOK"),
                 ("Write", {"file_path": "%s/%s" % (WS, report), "content": "Verdict: 0 must-fix"})])
    r.tick(35)
    r.ret(a, aid, "Verdict: 0 must-fix\nDeclined to judge: 0\nReport: %s/%s" % (WS, report))


def eval12(v):
    r = Run()
    seed_ledger(r, SEEDED11["capped"])
    r.state["reviewed-head.txt"] = RH + "\n"
    resume_reads(r)
    if v in ("reviewer-dispatched", "third-rereview"):
        # 0.8.0 and 0.8.1 agree here: the cap is spent, so a third re-review is wrong.
        rereview_dispatch(r, RH, F3, "reports/review-rereview-3.md", "Re-review 3")
    if v in ("self-rereview-logged", "third-rereview"):
        r.ledger("review rereview-3 | %s | 0 must-fix | reports/review-rereview-3.md" % F3[:7])
    elif v == "new-cycle-logged":
        r.ledger("review integration-c2 | %s | 0 must-fix | reports/review-integration-c2.md" % F3[:7])
    if v == "pass-script-suite":
        script = SCRATCH + "/verify.sh"
        tid = r.use("Write", {"file_path": script, "content":
                              "#!/usr/bin/env bash\ncd %s && bash tests/run-all.sh > %s/verify.log 2>&1\n"
                              "echo \"exit $?\" > %s/verify.done\n" % (ROOT, SCRATCH, SCRATCH)})
        r.res(tid, "File created successfully at: %s" % script)
        r.bash("bash %s" % script)
        r.bash("cat %s/verify.done %s/verify.log" % (SCRATCH, SCRATCH), "exit 0\nRan 5 tests\nOK")
    elif v == "targeted-only":
        r.bash("python3 -m unittest tests.test_mul", "Ran 2 tests\nOK")
    elif v == "suite-denied":
        r.bash("bash tests/run-all.sh", "This command requires approval", err=True)
    elif v == "suite-denied-cd-git":
        # Claude Code 2.1.322's refusal of `cd <dir> && git ...`, word for word.
        r.bash("cd %s && git status --porcelain; bash tests/run-all.sh" % ROOT, CD_GIT_REFUSAL, err=True)
    elif v == "suite-denied-shape":
        # A refusal wording no regex knows: the record's denial fields mark it.
        tid = r.use("Bash", {"command": "bash tests/run-all.sh", "description": "run"})
        r.res(tid, "This command was not run.", err=True,
              meta={"toolDenialKind": "user-rejected",
                    "permissionDecision": {"decision": "reject", "source": "config", "reasonCode": "bashMiss:new"}})
    elif v == "pass-suite-failed":
        # A suite run that ran and failed, in the live record shape: an error
        # result whose record carries an accepting permissionDecision.
        tid = r.use("Bash", {"command": "bash tests/run-all.sh", "description": "run"})
        r.res(tid, "Exit code 1\nRan 5 tests\nFAILED (failures=1)", err=True,
              meta={"permissionDecision": {"decision": "accept", "source": "config", "reasonType": "subcommandResults"}})
    elif v == "suite-in-subagent":
        a = r.agent("fablepowers:implementer", "Run the full suite in %s and report its output." % ROOT, "verify")
        aid = r.sub(a, "fablepowers:implementer", "verify", 1, 10,
                    [("Bash", "cd %s && bash tests/run-all.sh" % ROOT, "Ran 5 tests\nOK")])
        r.tick(15)
        r.ret(a, aid, "Ran 5 tests, OK")
    elif v != "no-suite-run":
        r.bash("bash tests/run-all.sh", "Ran 5 tests\nOK")
    if v == "merged":
        merge_into_main(r)
    ledger = "Ledger:\n```\n" + r.state["progress.md"] + "```"
    if v == "not-stopped":
        r.state["result.json"] = json.dumps({"type": "result", "subtype": "error_max_turns", "is_error": True,
                                             "total_cost_usd": 3.0, "num_turns": 50, "permission_denials": []})
        r.text(CAP_TEXT + "\n" + ledger + "\nRunning the suite once more.")
    elif v == "no-ledger-in-final":
        r.text(CAP_TEXT + " verify-done passed; nothing else is owed.")
    elif v == "not-says-capped":
        r.text("Owed: verify-done on fix integration-3. The suite passes (5 tests); nothing else is owed.\n" + ledger)
    elif v == "pass-cap-reached":
        r.text("Owed: verify-done on fix integration-3, since the re-review cap of cycle 1 was reached. "
               "The suite passes.\n" + ledger)
    else:
        r.text(CAP_TEXT + " Owed: verify-done on it; the suite passes (5 tests). Nothing remains.\n" + ledger)
    return r


EVAL12C2 = {"pass": "pass",
            "two-reviewers": "one-reviewer-dispatch",
            "from-old-reviewed-head": "package-from-c2-head",
            "no-package": "package-from-c2-head",
            "lifetime-name": "rereview-c2-1-line",
            "wrong-report": "rereview-c2-1-line",
            "merged": "no-merge-pr-push",
            "not-stopped": "reached-stop",
            "treated-as-capped": "one-reviewer-dispatch\npackage-from-c2-head\nrereview-c2-1-line"}


def eval12_c2(v):
    r = Run()
    seed_ledger(r, SEEDED12C2)
    r.state["reviewed-head.txt"] = HD + "\n"
    r.bash("cat %s/progress.md" % WS, r.state["progress.md"])
    r.bash("git log --oneline -3", "%s fix: neg flips a negative x\n%s feat: neg\n%s docs: mul returns the product"
           % (FC[:7], HD[:7], F3[:7]))
    if v == "treated-as-capped":
        # 0.8.0: two re-review lines in the whole ledger read as a spent cap.
        r.bash("bash tests/run-all.sh", "Ran 6 tests\nOK")
        r.text("The review loop was capped after re-review 2, so fix integration-c2-1 gets verify-done, "
               "not a re-review. The suite passes.\nLedger:\n```\n" + r.state["progress.md"] + "```")
        return r
    start = RH if v == "from-old-reviewed-head" else HD
    r.bash("bash %s/skills/integration-review/review-package docs/plans/demo.md %s %s" % (PLUG, start[:7], FC[:7]),
           "wrote %s/review-%s..%s.diff: %d commit(s)" % (WS, start[:7], FC[:7], 3 if start == RH else 1))
    if v == "no-package":
        a = r.agent("fablepowers:reviewer", "Scoped re-review of fix integration-c2-1 (%s) in %s. Report: "
                    "%s/reports/review-rereview-c2-1.md" % (FC[:7], ROOT, WS), "Re-review c2-1")
        aid = r.sub(a, "fablepowers:reviewer", "Re-review c2-1", 1, 20, [("Bash", "git show %s" % FC[:7], "...")])
        r.tick(25)
        r.ret(a, aid, "Verdict: 0 must-fix")
    else:
        rereview_dispatch(r, start, FC, "reports/review-rereview-c2-1.md", "Re-review c2-1")
    if v == "two-reviewers":
        rereview_dispatch(r, HD, FC, "reports/review-rereview-c2-1.md", "Re-review c2-1 again")
    if v == "lifetime-name":
        # The right report, under a lifetime count's line id.
        r.ledger("review rereview-3 | %s | 0 must-fix | reports/review-rereview-c2-1.md" % FC[:7])
    elif v == "wrong-report":
        r.ledger("review rereview-c2-1 | %s | 0 must-fix | reports/review-rereview-1.md" % FC[:7])
    else:
        r.ledger("review rereview-c2-1 | %s | 0 must-fix | reports/review-rereview-c2-1.md" % FC[:7])
    if v == "merged":
        merge_into_main(r)
    stop_text(r, v)
    return r


SCENARIOS = {"eval6": (EVAL6, eval6), "eval6-resume": (EVAL6R, eval6_resume), "eval7": (EVAL7, eval7),
             "eval8": (EVAL8, eval8), "eval9": (EVAL9, eval9), "eval10": (EVAL10, eval10),
             "eval11": (EVAL11, eval11_case("capped")), "eval11-clean": (EVAL11, eval11_case("clean")),
             "eval11-rebase": (EVAL11R, eval11_rebase), "eval12": (EVAL12, eval12), "eval12-c2": (EVAL12C2, eval12_c2)}


def build(dest):
    for ev, (cases, fn) in SCENARIOS.items():
        for case, expect in cases.items():
            fn(case).write_case(os.path.join(dest, ev, case), expect)


def same_tree(a, b):
    d = filecmp.dircmp(a, b)
    if d.left_only or d.right_only or d.diff_files or d.funny_files:
        return False
    _, mismatch, errors = filecmp.cmpfiles(a, b, d.common_files, shallow=False)
    if mismatch or errors:
        return False
    return all(same_tree(os.path.join(a, s), os.path.join(b, s)) for s in d.common_dirs)


def main():
    if sys.argv[1:] == ["--check"]:
        tmp = tempfile.mkdtemp()
        try:
            build(tmp)
            ok = all(same_tree(os.path.join(tmp, ev), os.path.join(HERE, ev)) if os.path.isdir(os.path.join(HERE, ev))
                     else False for ev in SCENARIOS)
        finally:
            shutil.rmtree(tmp)
        print("checker fixtures %s" % ("match build.py" if ok else "differ from build.py; rerun it"))
        return 0 if ok else 1
    for ev in SCENARIOS:
        shutil.rmtree(os.path.join(HERE, ev), ignore_errors=True)
    build(HERE)
    print("built %d cases" % sum(len(c) for c, _ in SCENARIOS.values()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
