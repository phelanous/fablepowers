"""Eval 8: two independent tasks that share a `serialize` resource (e2e)
never run at the same time (spec "How we'll know it works" 8).
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402


def main():
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker("eval8")
    d = ec.task_dispatches(s)
    t1, t2 = d.get("1", []), d.get("2", [])

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

    ec.assert_stopped(s, c, ["1", "2"])
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
