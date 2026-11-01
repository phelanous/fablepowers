"""Eval 10: plan review of a plan where T2 depends on T1 only for the Color
enum, and T3 has no Depends on line. The reviewer flags both (spec "How
we'll know it works" 10; the checks are implementation-plan's plan-review
checks 1, 2 and 4).

The report is read paragraph by paragraph (blank lines, list items, table
rows and headings split it); a finding is a paragraph naming the task and the
defect.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402


def paragraphs(text):
    return [p for p in re.split(r"\n\s*\n|\n(?=\s*(?:[-*+]|\d+[.)])\s)|\n(?=#)|\n(?=\s*\|)", text) if p.strip()]


def names(tid):
    return re.compile(r"\b(?:T|Task\s*)%s\b" % tid, re.I)


def main():
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker("eval10")

    reviewers = [x for x in s.agent_calls() if "reviewer" in x.subagent_type and "review-plan.md" in x.prompt]
    c.check("reviewer-dispatched", bool(reviewers),
            "%s with reports/review-plan.md" % reviewers[0].subagent_type if reviewers else
            "no fablepowers:reviewer dispatch naming reports/review-plan.md")

    report = s.report("reports/review-plan.md")
    paras = paragraphs(report)
    enum = [p for p in paras if names("2").search(p) and re.search(r"\benum|contract", p, re.I)]
    c.check("flags-enum-only-dependency", bool(enum),
            "found: %s" % " ".join(enum[0].split())[:120] if enum else
            ("no paragraph naming T2 with enum/contract" if report else "no reports/review-plan.md"))

    dep = [p for p in paras if names("3").search(p) and re.search(r"depends\s+on|no-depends", p, re.I)]
    c.check("flags-missing-depends-on", bool(dep),
            "found: %s" % " ".join(dep[0].split())[:120] if dep else
            ("no paragraph naming T3 with Depends on / no-depends" if report else "no reports/review-plan.md"))

    res = s.result()
    impl = [x for x in s.agent_calls() if "implementer" in x.subagent_type]
    problems = []
    if res.get("subtype") != "success" or res.get("is_error"):
        problems.append("result subtype %r" % res.get("subtype"))
    if impl:
        problems.append("%d implementer dispatch(es)" % len(impl))
    c.check("stopped-after-review", not problems, "; ".join(problems) or "result success, no implementer dispatched")
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
