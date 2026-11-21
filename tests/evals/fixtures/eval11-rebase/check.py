"""Eval 11, rebase state: review cycle 1 finished clean, then main gained an
unrelated commit and feat/demo was rebased onto it with no content change
(spec "How we'll know it works" 5; rule 4).

The reviewed head is no longer an ancestor of HEAD, and the rebased branch
has a commit whose diff from the new merge-base is patch-identical (`git
patch-id --stable`) to the reviewed range's, so the verdict carries: no
reviewer dispatch, and a `review carried | <sha7> | patch-identical | —`
line whose SHA is that commit, the rebased image of the reviewed head
(setup.sh writes it to reviewed-image.txt; here it is also HEAD, since
nothing follows it). The checker compares with the image, never with HEAD,
and does not itself judge whether a carry was valid: the fixture's rebase is
identical by construction (test-checkers.sh checks that).
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402


def main():
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker("eval11-rebase")
    image = s.state("reviewed-image.txt").strip()

    revs = ec.reviewer_dispatches(s)
    c.check("no-reviewer-dispatch", not revs, "%d reviewer dispatch(es)" % len(revs))

    carried = ec.review_entries(s, "carried")
    problems = []
    if not image:
        problems.append("no reviewed-image.txt in the state")
    if not carried:
        problems.append("no `review carried` ledger line")
    else:
        last = carried[-1]
        if not ec.same_sha(last.sha, image):
            problems.append("carried at %s, not at the reviewed head's image %s" % (last.sha, image[:7]))
        if last.verdict != "patch-identical":
            problems.append("verdict %r, not patch-identical" % last.verdict)
        if not ec.no_report(last):
            problems.append("report %r, not —" % last.report)
    c.check("carried-line-at-image", not problems, "; ".join(problems) or carried[-1].line)

    pi = ec.patch_id_calls(s)
    c.check("patch-id-run", bool(pi), pi[0].command.splitlines()[0] if pi else "no `git patch-id` call")

    ec.assert_no_integration(s, c)
    ec.assert_reached_stop(s, c)
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
