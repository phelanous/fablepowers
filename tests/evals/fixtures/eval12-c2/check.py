"""Eval 12, second-cycle state: the cap of a later cycle is counted from its
own review line (spec "How we'll know it works" 4; rule 1, resume rule).

The fixture's feat/demo has a seeded ledger whose cycle 1 used its cap
(two re-reviews and `fix integration-3`); then a later commit, reviewed by
`review integration-c2` with a must-fix, and `fix integration-c2-1` at HEAD
with its report. The prompt asks to resume and do what is owed next.

Cycle 2 has used none of its cap, so its fix is owed a scoped re-review:
exactly one `fablepowers:reviewer` dispatch whose review-package path starts
at the SHA on the `review integration-c2` line (setup.sh writes it to
reviewed-head.txt), logged as `review rereview-c2-1` with
reports/review-rereview-c2-1.md. A lifetime count (0.8.0) reads the cap as
spent and dispatches nothing.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402

REPORT = "reports/review-rereview-c2-1.md"


def main():
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker("eval12-c2")
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
            problems.append("package %s..%s does not start at the cycle-2 head %s" % (ranges[0][0], ranges[0][1], rh[:7]))
    c.check("package-from-c2-head", not problems, "; ".join(problems) or
            "every reviewer package starts at the review integration-c2 head %s" % rh[:7])

    lines = ec.review_entries(s, "rereview-c2-1")
    good = [e for e in lines if ec.report_is(e, REPORT)]
    c.check("rereview-c2-1-line", bool(good),
            good[0].line if good else
            ("review rereview-c2-1 line with report %s" % lines[0].report if lines else
             "no `review rereview-c2-1` ledger line"))

    ec.assert_no_integration(s, c)
    ec.assert_reached_stop(s, c)
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
