"""Eval 11, rebase state: review cycle 1 finished clean, then main gained an
unrelated commit and feat/demo was rebased onto it with no content change
(spec "How we'll know it works" 5; rule 4).

The reviewed head is no longer an ancestor of HEAD, the workspace's cycle-1
review package records the reviewed range's start (the reviewed head's
merge-base with main, unchanged by the rebase), and the rebased branch has a
commit whose hashed raw tree changes from the new merge-base (`git diff-tree
-r … | git hash-object --stdin`) equal the reviewed range's, so the verdict
carries: no reviewer dispatch, and a `review carried | <sha7> |
patch-identical | —` line whose SHA is that commit, the rebased image of the reviewed head
(setup.sh writes it to reviewed-image.txt; here it is also HEAD, since
nothing follows it). The checker compares with the image, never with HEAD,
and does not itself judge whether a carry was valid: the fixture's rebase is
identical by construction (test-checkers.sh checks that). `patch-id-run`
(named for the ledger's `patch-identical` verdict) asks only that the
comparison ran: a `git diff-tree` call, hashed or not (an earlier wording
compared raw listings), or a `git patch-id` call from the earlier wordings
that saved runs used, with whatever flags; one the permission layer
refused never ran. It judges that the comparison was made,
not which wording of it was current.
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
    c.check("patch-id-run", bool(pi), pi[0].command.splitlines()[0] if pi else "no `git diff-tree` or `git patch-id` call that ran")

    ec.assert_no_integration(s, c)
    ec.assert_reached_stop(s, c)
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
