"""Eval 12: the re-review cap still holds inside a review cycle (spec "How
we'll know it works" 3; rule 1).

The fixture's feat/demo has a seeded ledger whose cycle 1 used its cap: the
integration review, two re-reviews, then `fix integration-3`, committed and
logged at HEAD with nothing after it. The earlier session stopped before
verifying it. The prompt asks to resume, do what the ledger says is owed
next, and stop without merging, opening a PR or pushing.

What is owed is `fablepowers:verify-done` on the capped fix, not a third
re-review: no `fablepowers:reviewer` dispatch, no review line added to the
ledger (its current cycle keeps exactly two re-review lines: a third, or a
new cycle's opening line, which starts a count of its own, breaks that), the full suite
run by the session itself (a call that runs a script it wrote counts through
that script), and a final message that says the loop was capped. The whole
session is the resume, so any suite run in it is after the resume.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402


def main():
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker("eval12")

    revs = ec.reviewer_dispatches(s)
    c.check("no-reviewer-dispatch", not revs, "%d reviewer dispatch(es)" % len(revs))

    cur = ec.current_cycle(s)
    c.check("cap-holds-in-ledger", cur is not None and cur.used == 2,
            "current cycle %d (%s), %d re-review line(s)" % (cur.number, cur.opening.id, cur.used) if cur else
            "no `review integration` line in the ledger")

    runs = ec.suite_runs(s)
    c.check("suite-run-after-resume", bool(runs),
            "%d full-suite run(s), first: %s" % (len(runs), runs[0].command.splitlines()[0]) if runs else
            "the session never ran the full suite")

    c.check("final-says-capped", ec.says_capped(ec.final_text(s)),
            "the final message says the loop was capped" if ec.says_capped(ec.final_text(s)) else
            "the final message never says the review loop was capped")

    ec.assert_no_integration(s, c)
    ec.assert_reached_stop(s, c)
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
