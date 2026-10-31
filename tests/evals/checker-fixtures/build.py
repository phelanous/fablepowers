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
`expect` file holds `pass` or the name of the one assertion that must fail.
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
            "exclude.txt": "# git ls-files --others --exclude-from=.git/info/exclude\n\n.worktrees/\n",
            "gitignore-head.txt": "__pycache__/\n*.pyc\n",
            "log.txt": "",
            "first-parent.txt": "",
        }
        self.files = {}

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

    def res(self, tid, text="", err=False, agent=None, t=None, extra=None):
        rec = {"type": "user", "timestamp": t or self.tick(), "isSidechain": bool(agent),
               "message": {"role": "user", "content": [
                   {"tool_use_id": tid, "type": "tool_result", "content": text, "is_error": err}]}}
        if agent:
            rec["agentId"] = agent
        if extra:
            rec["toolUseResult"] = extra
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
        os.makedirs(os.path.join(path, "session", "subagents"), exist_ok=True)
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


def exclude(r):
    r.bash('EXCLUDE="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"; '
           "grep -qxF '.worktrees/' \"$EXCLUDE\" 2>/dev/null || printf '\\n.worktrees/\\n' >> \"$EXCLUDE\"; "
           "git check-ignore -q .worktrees/ && echo ignored", "ignored")


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
        r.ledger("check %s | %s | PASS | —" % (t, sha))
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
    r.ledger("check %s | abc12%02d | PASS | —" % (t, int(t)))
    r.ledger("task %s | abc12%02d | DONE | reports/task-%s.md" % (t, int(t), t))


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
         "gitignore-commit": "worktrees-ignored-via-exclude",
         "status-shows-worktrees": "worktrees-ignored-via-exclude",
         "not-stopped": "stopped-before-review"}


def eval6(v):
    r = Run()
    start(r)
    if v == "gitignore-commit":
        r.bash("printf '.worktrees/\\n' >> .gitignore && git add .gitignore && git commit -m 'chore: ignore .worktrees'")
        r.state["gitignore-head.txt"] += ".worktrees/\n"
        r.state["exclude.txt"] = "# git ls-files --others --exclude-from=.git/info/exclude\n"
    elif v == "status-shows-worktrees":
        r.state["exclude.txt"] = "# git ls-files --others --exclude-from=.git/info/exclude\n"
        r.state["status.txt"] = "?? .worktrees/\n"
    else:
        exclude(r)
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
    exclude(r)
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
    exclude(r)
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
        r.bash("git diff main fp/demo/t2 -- app/config.py", "-PAGE_SIZE = 50\n+PAGE_SIZE = 100")
    if v == "ledger-before-fix":
        r.ledger("merge 2-1 | abc1250 | DONE | reports/task-2-merge1.md")
    if v != "no-merge-fix":
        mp = ("Merge fix for T2. Task branch fp/demo/t2 in %s; plan branch main at abc1201 conflicted with it in "
              "app/config.py (T1 and T2 both set PAGE_SIZE). Merge main into the task branch, resolve, run both "
              "tasks' tests and the full suite, commit. Plan: %s/docs/plans/demo.md. Report: %s/reports/task-2-merge1.md"
              % (w2, ROOT, WS))
        mf = r.agent("fablepowers:implementer", mp, "T2 merge fix")
        smf = r.sub(mf, "fablepowers:implementer", "T2 merge fix", 1, 40, [
            ("Bash", "git -C %s merge main" % w2, CONFLICT),
            ("Edit", {"file_path": w2 + "/app/config.py", "old_string": "<<<<<<<", "new_string": "PAGE_SIZE = 100"}),
            ("Bash", "cd %s && bash tests/run-all.sh" % w2, "OK"),
            ("Bash", "git -C %s commit --no-edit -a" % w2, "")])
        r.tick(45)
        r.ret(mf, smf)
    if v == "orchestrator-edit":
        tid = r.use("Edit", {"file_path": ROOT + "/app/config.py", "old_string": "PAGE_SIZE = 50",
                             "new_string": "PAGE_SIZE = 100"})
        r.res(tid, "updated")
    if v == "ledger-not-in-file":
        # The append command ran, but the line never reached progress.md.
        r.bash("printf '%%s\\n' 'merge 2-1 | abc1250 | DONE | reports/task-2-merge1.md' >> %s/progress.md" % WS)
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
         "not-stopped": "stopped-before-review"}


def eval8(v):
    r = Run()
    start(r)
    if v == "overlap":
        a1 = r.agent("fablepowers:implementer", task_prompt("1", ROOT + "/.worktrees/demo-t1"), "T1 shout", msg="msg_w")
        a2 = r.agent("fablepowers:implementer", task_prompt("2", ROOT + "/.worktrees/demo-t2"), "T2 clamp", msg="msg_w")
        s1 = r.sub(a1, "fablepowers:implementer", "T1 shout", 1, 50, impl_steps(ROOT, "strings"))
        s2 = r.sub(a2, "fablepowers:implementer", "T2 clamp", 2, 45, impl_steps(ROOT, "nums"))
        r.tick(55)
        r.ret(a1, s1)
        r.ret(a2, s2)
        merge_task(r, "1")
        merge_task(r, "2")
    else:
        in_place(r, "1", "strings")
        if v == "one-dispatch":
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
            aid = r.sub(a, "fablepowers:implementer", "T2 nums", -60, -30, impl_steps(ROOT, "nums"))
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


SCENARIOS = {"eval6": (EVAL6, eval6), "eval6-resume": (EVAL6R, eval6_resume), "eval7": (EVAL7, eval7),
             "eval8": (EVAL8, eval8), "eval9": (EVAL9, eval9), "eval10": (EVAL10, eval10)}


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
