"""Eval 8: two independent tasks that share a `serialize` resource (e2e)
never run at the same time (spec "How we'll know it works" 8), while a third
independent task with `Touches: none` does run alongside one of them.

The third task is the control. Without it, any one-at-a-time fallback passes
`serialized-no-overlap` (integration review Minor 4). It also checks the run
resource rule (integration review M2): an implementer whose task doesn't
touch the serialized e2e runs the plan's pre-commit suite, which leaves the
e2e out, never the full suite with it. A Bash call that runs a script the
agent wrote is read together with that script.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402

# The plan's one serialize run resource, the command that runs its part, and
# the full suite, which runs every part (see ec.unheld_parts).
PARTS = {"e2e": re.compile(r"tests/e2e\.sh")}
FULL = re.compile(r"tests/run-all\.sh")
PRE_COMMIT = re.compile(r"\bpython3?\s+(?:-\w+\s+)*-m\s+unittest\s+discover\b")


def main():
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker("eval8")
    d = ec.task_dispatches(s)
    t1, t2, t3 = d.get("1", []), d.get("2", []), d.get("3", [])

    c.check("both-dispatched", bool(t1) and bool(t2), "T1 %d, T2 %d dispatch(es)" % (len(t1), len(t2)))

    if t1 and t2:
        a, b = sorted([t1[0], t2[0]], key=lambda x: x.idx)
        sa, sb = s.segments(a), s.segments(b)
        problems = []
        if a.result_idx is None or b.idx < a.result_idx:
            problems.append("second dispatch issued before the first returned")
        if not sa or not sb:
            problems.append("missing interval (%s, %s)" % (bool(sa), bool(sb)))
        elif ec.overlap(sa, sb):
            problems.append("active intervals overlap: %s / %s" % (sa, sb))
        c.check("serialized-no-overlap", not problems, "; ".join(problems) or "%s ends before %s starts" % (
            sa[-1][1], sb[0][0]))
    else:
        c.check("serialized-no-overlap", True, "not judged: fewer than two tasks dispatched")

    s3 = s.segments(t3[0]) if t3 else []
    with_t3 = [n for n, ts in (("T1", t1), ("T2", t2)) if ts and s3 and ec.overlap(s3, s.segments(ts[0]))]
    c.check("control-overlaps", bool(with_t3),
            "T3 active alongside %s" % ", ".join(with_t3) if with_t3 else
            ("T3 never active alongside T1 or T2" if t3 else "T3 not dispatched"))

    impl = s.subagent_for(t3[0]) if t3 else None
    calls = impl["calls"] if impl else []
    scripts = {x.path: x.input.get("content") or "" for x in calls if x.name == "Write" and x.path}

    def text(x):
        return "\n".join([x.command] + [body for path, body in scripts.items() if path in x.command])

    ran = [text(x) for x in calls if x.name == "Bash" and not ec.denied(x)]
    e2e = [line for _, line in ec.unheld_parts(ran, PARTS, FULL, set())]  # T3: Touches none
    pre = [r for r in ran if PRE_COMMIT.search(r)]
    c.check("control-pre-commit-suite", impl is not None and not e2e and bool(pre),
            "T3 ran the e2e: %s" % e2e[0] if e2e else
            ("T3 ran the pre-commit suite %d time(s), never the e2e" % len(pre) if pre else
             ("T3 never ran the pre-commit suite" if impl else "no T3 implementer transcript")))

    ec.assert_stopped(s, c, ["1", "2", "3"])
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
