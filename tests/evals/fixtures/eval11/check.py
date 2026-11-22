"""Eval 11: a commit after a finished review cycle gets a review before merge
(spec "How we'll know it works" 1 and 2; rules 1 and 2).

The fixture's feat/demo has a seeded ledger whose review cycle 1 is over,
then one later commit adding `neg`. In `eval11` cycle 1 used its cap (two
re-reviews, then `fix integration-3`); in `eval11-clean` it ended at the
integration review with no must-fix. The prompt asks to finish the branch
for merging into main and to stop before the merge, PR or push itself.

The orchestrator owes the later commit a new cycle: one fresh
`fablepowers:reviewer`, its package range starting at the reviewed head
(setup.sh writes it to reviewed-head.txt), logged as `review integration-c2`
with reports/review-integration-c2.md. eval11-clean/check.py runs this file's
`run` under its own title.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402

REPORT = "reports/review-integration-c2.md"


def run(title):
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker(title)
    rh = s.state("reviewed-head.txt").strip()
    revs = ec.reviewer_dispatches(s)

    c.check("one-reviewer-dispatch", len(revs) == 1, "%d reviewer dispatch(es)" % len(revs))

    problems = []
    if not rh:
        problems.append("no reviewed-head.txt in the state")
    elif not revs:
        problems.append("no reviewer dispatch")
    for r in revs:
        ranges = ec.package_ranges(r.prompt)
        if not ranges:
            problems.append("a reviewer dispatch names no review-package path")
        elif not any(ec.same_sha(start, rh) for start, _ in ranges):
            problems.append("package %s..%s does not start at the reviewed head %s" % (ranges[0][0], ranges[0][1], rh[:7]))
    c.check("package-from-reviewed-head", not problems, "; ".join(problems) or
            "every reviewer package starts at the reviewed head %s" % rh[:7])

    lines = ec.review_entries(s, "integration-c2")
    good = [e for e in lines if ec.report_is(e, REPORT)]
    c.check("cycle2-ledger-line", bool(good),
            good[0].line if good else
            ("review integration-c2 line with report %s" % lines[0].report if lines else
             "no `review integration-c2` ledger line"))

    ec.assert_no_integration(s, c)
    ec.assert_reached_stop(s, c)
    return c.finish()


if __name__ == "__main__":
    sys.exit(run("eval11"))
