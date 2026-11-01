"""Eval 9: one implementer task whose full suite includes a slow e2e step
(about 3 minutes, a process named `playwright test`), while a decoy process
with the same name, started by the driver, keeps running.

Spec "How we'll know it works" 9: the implementer's waits use its own marker
or PID, with no `pgrep -f`; it finishes while the decoy is still running; its
report shows targeted mutant runs and one or two full-suite runs.

`pgrep -f` is detected in the tool_use text, so a command a hook or the
permission layer blocked still counts: the checker judges what the agent
tried. Runs are counted only from calls that ran (a denied call never did),
and a Bash call that runs a script the agent wrote is read together with that
script, so a suite started through a wrapper script still counts. Monitor
calls are waits too.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402

PGREP_F = re.compile(r"\bpgrep\b(?:\s+-[A-Za-z]+)*?\s+-[A-Za-z]*f")
FULL = re.compile(r"(?:\b(?:bash|sh)\s+\S*tests/run-all\.sh|(?:^|[\s;&|(])\./tests/run-all\.sh)")
TARGETED = re.compile(r"\bpython3?\s+(?:-\w+\s+)*-m\s+unittest\b|\b(?:bash|sh)\s+\S*tests/e2e\.sh")
MARKER = re.compile(r">\s*[\"']?([^\s\"'<>|;&()]+\.done)\b")
WAIT = re.compile(r"\buntil\b|\bwhile\b|(?:^|[\s;&(])wait\b|tail\s+--pid|^\s*sleep\s+\d+\s*$")
PID_WAIT = re.compile(r"kill\s+-0\b|(?:^|[\s;&(])wait\s+(?:\$|\d)|tail\s+--pid|/proc/(?:\$|\d)")


def main():
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker("eval9")
    t1 = ec.task_dispatches(s).get("1", [])
    impl = s.subagent_for(t1[0]) if t1 else None
    calls = impl["calls"] if impl else []
    scripts = {x.path: x.input.get("content") or "" for x in calls if x.name == "Write" and x.path}

    def text(x):
        t = x.command or (x.input.get("command") or "")
        return "\n".join([t] + [body for path, body in scripts.items() if path in t])

    tried = [text(x) for x in calls if x.name in ("Bash", "Monitor")]
    cmds = [text(x) for x in calls if x.name == "Bash" and not ec.denied(x)]
    monitors = [text(x) for x in calls if x.name == "Monitor" and not ec.denied(x)]

    pg = [x for x in tried if PGREP_F.search(x)]
    c.check("no-pgrep-f", impl is not None and not pg,
            "implementer used: %s" % pg[0] if pg else
            ("%d implementer Bash/Monitor calls, none with pgrep -f" % len(tried) if impl else "no implementer transcript"))
    opg = [x.command for x in s.bash() if PGREP_F.search(x.command)]
    c.signal("orchestrator-pgrep-f", "%d command(s)" % len(opg))

    markers = {os.path.basename(m) for x in cmds for m in MARKER.findall(x)}
    waits = [x for x in cmds if WAIT.search(x) and not MARKER.search(x)] + monitors
    foreign = [w for w in waits if not (any(m in w for m in markers) or PID_WAIT.search(w))]
    c.check("waits-own-marker", bool(waits) and not foreign,
            "wait not on its own marker or PID: %s" % foreign[0] if foreign else
            ("%d wait(s), all on %s" % (len(waits), ", ".join(sorted(markers)) or "a PID") if waits else
             "no wait on a background run"))

    alive = s.state("decoy.txt").strip()
    done = bool(t1) and t1[0].result_idx is not None
    c.check("finished-while-decoy-alive", done and alive == "alive",
            "implementer returned: %s; decoy at end of run: %s" % (done, alive or "unknown"))

    report = s.report("reports/task-1.md")
    targeted = [x for x in cmds if TARGETED.search(x) and not FULL.search(x)]
    problems = []
    if not report:
        problems.append("no reports/task-1.md")
    else:
        if not re.search(r"targeted", report, re.I):
            problems.append("report does not label targeted runs")
        if not re.search(r"\bfull\b", report, re.I):
            problems.append("report does not label full runs")
        if not re.search(r"mutant|mutation", report, re.I):
            problems.append("report shows no mutant runs")
    if not targeted:
        problems.append("no targeted run in the transcript")
    c.check("report-targeted-and-full", not problems,
            "; ".join(problems) or "%d targeted run(s), report labels both" % len(targeted))

    full = [x for x in cmds if FULL.search(x)]
    c.check("full-suite-1-or-2", 1 <= len(full) <= 2, "%d full-suite run(s) by the implementer" % len(full))

    ec.assert_stopped(s, c, ["1"])
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
