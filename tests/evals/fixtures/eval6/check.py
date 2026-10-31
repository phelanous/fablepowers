"""Eval 6: two independent tasks (T1, T2) and one dependent task (T3, on T2).

Spec "How we'll know it works" 6 and 12, plan Review Focus 2.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402

KEY = "demo"


def main():
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker("eval6")
    d = ec.task_dispatches(s)
    t1, t2, t3 = d.get("1", []), d.get("2", []), d.get("3", [])

    # The two independent dispatches appear in one assistant message.
    same = [(a, b) for a in t1 for b in t2 if a.msg_id and a.msg_id == b.msg_id]
    c.check("independent-dispatches-one-message", bool(same),
            "T1/T2 share message %s" % same[0][0].msg_id if same else
            "T1 dispatches %d, T2 dispatches %d, no shared message" % (len(t1), len(t2)))

    # ... each naming its own .worktrees/ task worktree.
    if t1 and t2:
        w1, w2 = ec.worktree_paths(t1[0].prompt), ec.worktree_paths(t2[0].prompt)
        ok = bool(w1) and bool(w2) and not (w1 & w2)
        detail = "T1 %s, T2 %s" % (sorted(w1) or "none", sorted(w2) or "none")
    else:
        ok, detail = False, "T1 or T2 not dispatched"
    c.check("own-task-worktree", ok, detail)

    # ... and their active intervals overlap.
    if t1 and t2:
        sa, sb = s.segments(t1[0]), s.segments(t2[0])
        ok = bool(sa) and bool(sb) and ec.overlap(sa, sb)
        detail = "T1 %s, T2 %s" % (sa or "no interval", sb or "no interval")
        if sa and sb:
            c.signal("wave-1-concurrency", "%.2f (success signal: above 1.5)" % ec.concurrency([sa, sb]))
    else:
        ok, detail = False, "T1 or T2 not dispatched"
    c.check("active-intervals-overlap", ok, detail)

    # The dependent task is dispatched only after both task lines.
    i1, i2 = ec.ledger_write_idx(s, "task", "1"), ec.ledger_write_idx(s, "task", "2")
    if not t3:
        ok, detail = False, "T3 not dispatched"
    elif i1 is None or i2 is None:
        ok, detail = False, "task line write not found (T1 %s, T2 %s)" % (i1, i2)
    else:
        ok = t3[0].idx > max(i1, i2)
        detail = "T3 dispatched at %d, task lines at %d and %d" % (t3[0].idx, i1, i2)
    c.check("dependent-after-both-task-lines", ok, detail)

    # Each merge is --no-ff, with a check line after it.
    ec.assert_merges_no_ff(s, c, KEY, ["1", "2", "3"], required=["1", "2"])
    ec.assert_check_after_merges(s, c, KEY, ["1", "2", "3"])

    # Task worktrees and branches are gone at the end.
    ec.assert_cleanup(s, c, KEY)

    # Review Focus 2: the fixture repo has no ignore entry; .worktrees/ never
    # shows in git status, and the ignore comes from info/exclude, not a
    # committed .gitignore.
    status = [l for l in s.state("status.txt").splitlines() if ".worktrees" in l]
    excl = any(l.strip().rstrip("/") in (".worktrees", "/.worktrees") for l in s.state("exclude.txt").splitlines())
    gi = ".worktrees" in s.state("gitignore-head.txt")
    problems = []
    if status:
        problems.append("git status shows %s" % status[0].strip())
    if not excl:
        problems.append("info/exclude has no .worktrees/ entry")
    if gi:
        problems.append(".gitignore at HEAD names .worktrees")
    c.check("worktrees-ignored-via-exclude", not problems, "; ".join(problems) or "info/exclude entry, status clean")

    ec.assert_stopped(s, c, ["1", "2", "3"])
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
