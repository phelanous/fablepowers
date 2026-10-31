"""Eval 6, second run: the fixture starts with a pre-existing fp/demo/t2 branch
holding a commit, as a crashed run would leave it (plan Review Focus 1).

The orchestrator resumes it: no re-dispatch of T2, the branch is never
recreated, deleted or reset, and its original commit is merged.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402

KEY = "demo"
RECREATE = re.compile(
    r"\bgit\b.*\b(?:worktree\s+add\b.*\s-[bB]\s+|branch\b.*\s(?:-D|-f|--force|-M|--delete)\s+.*|"
    r"checkout\b.*\s-[bB]\s+|switch\b.*\s-[cC]\s+|update-ref\s+-d\s+(?:refs/heads/)?)fp/%s/t2(?![\w])" % KEY)


def main():
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker("eval6-resume")
    d = ec.task_dispatches(s)

    c.check("t2-not-redispatched", not d.get("2"),
            "%d T2 task dispatch(es)" % len(d.get("2", [])))

    bad = [seg for x in s.bash() for seg in ec.segments_of(x.command) if RECREATE.search(seg)]
    merged = s.state("t2-merged.txt").strip()
    problems = []
    if bad:
        problems.append("recreated or deleted: %s" % bad[0])
    if merged != "yes":
        problems.append("pre-existing T2 commit merged into main: %s" % (merged or "unknown"))
    c.check("t2-branch-resumed", not problems, "; ".join(problems) or "branch kept, its commit merged")

    ec.assert_merges_no_ff(s, c, KEY, ["1", "2", "3"], required=["2"])
    ec.assert_check_after_merges(s, c, KEY, ["1", "2", "3"])
    ec.assert_cleanup(s, c, KEY)
    ec.assert_stopped(s, c, ["1", "2", "3"])
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
