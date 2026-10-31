"""Eval 7: two tasks set the same constant, app/config.py PAGE_SIZE, to
different values (T1 50, T2 100), so merging T2 conflicts. setup.sh seeds a
crashed run's state, T1 merged and T2's branch finished (see its comment for
why the conflict is seeded rather than produced live).

A merge counts as conflicting only when it ran and git reported a conflict;
a merge the permission layer denied never ran.

Spec "How we'll know it works" 7: `git merge --abort` and a merge-fix
dispatch, no orchestrator edit to the conflicted file, a merge ledger line;
plan T7: no orchestrator Bash naming that file or using --ours/--theirs
between the abort and the merge fix's return, and the resolving merge commit
on the task branch.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import evalcheck as ec  # noqa: E402

KEY = "demo"
CONFLICTED = "app/config.py"


def main():
    transcript, state = ec.args()
    s = ec.Session(transcript, state)
    c = ec.Checker("eval7")

    conflicts = [(call, seg, t) for t in ("1", "2") for call, seg in ec.merge_calls(s, KEY, t)
                 if ec.merge_conflicted(call)]
    files = {CONFLICTED}
    for call, _, _ in conflicts:
        files.update(re.findall(r"Merge conflict in (\S+)", call.result_text))
    first = conflicts[0][0] if conflicts else None
    aborts = [x for x in s.bash() if any(re.search(r"\bgit\b(?:\s+-C\s+\S+)?\s+merge\s+--abort\b", seg)
                                         for seg in ec.segments_of(x.command))]
    abort = next((a for a in aborts if first is not None and a.idx >= first.idx), None)
    c.check("merge-abort", abort is not None,
            "abort at %d after the conflicting merge at %d" % (abort.idx, first.idx) if abort else
            "conflicting merges %d, aborts %d" % (len(conflicts), len(aborts)))

    fixes = [x for x in s.agent_calls() if ec.classify_dispatch(x)[0] == "merge"]
    fix = next((f for f in fixes if first is not None and f.idx > first.idx and "implementer" in f.subagent_type), None)
    c.check("merge-fix-dispatched", fix is not None,
            "%s merge fix for T%s" % (fix.subagent_type, ec.classify_dispatch(fix)[1]) if fix else
            "%d merge-fix dispatch(es), none an implementer after the conflict" % len(fixes))

    tid = ec.classify_dispatch(fix)[1] if fix else (conflicts[0][2] if conflicts else "2")
    rx = re.compile(r"(?<![\w-])merge\s+T?%s-\d+\s*\|" % re.escape(tid), re.I)
    lines = [l for l in s.progress().splitlines() if rx.match(l.strip())]
    writes = [x for x in s.calls if (x.name == "Bash" and "progress.md" in x.command and rx.search(x.command)) or
              (x.name in ec.EDIT_TOOLS and x.path.endswith("progress.md") and rx.search(x.written_text()))]
    # The line follows the merge fix's return; with no merge fix (judged
    # above) only its presence is judged here.
    after = fix is None or (fix.result_idx is not None and any(w.idx > fix.result_idx for w in writes))
    c.check("merge-ledger-line", bool(lines) and after,
            "%s, written after the merge fix returned: %s" % (lines[0].strip() if lines else "no merge line", after))

    edits = [x for x in s.calls if x.name in ec.EDIT_TOOLS and any(x.path.endswith(f) for f in files)]
    c.check("no-orchestrator-edit-conflicted-file", not edits,
            "%s on %s" % (edits[0].name, edits[0].path) if edits else "no edit-tool call on %s" % ", ".join(sorted(files)))

    window = []
    begin = abort if abort is not None else first
    if begin is not None:
        end = fix.result_idx if fix is not None and fix.result_idx is not None else float("inf")
        for x in s.bash():
            if begin.idx < x.idx < end:
                names = [f for f in files if f in x.command or os.path.basename(f) in x.command]
                if names or re.search(r"--(?:ours|theirs)\b", x.command):
                    window.append(x.command)
    c.check("no-orchestrator-bash-on-conflict", not window,
            "between abort and merge-fix return: %s" % window[0] if window else "no Bash naming the file or --ours/--theirs")

    parents = {}
    for line in s.state("log.txt").splitlines():
        head = line.split("|", 1)[0].split()
        if head:
            parents[head[0]] = head[1:]
    on_branch = []
    for sha in s.state("first-parent.txt").split():
        ps = parents.get(sha, [])
        if len(ps) >= 2 and len(parents.get(ps[1], [])) >= 2:
            on_branch.append(ps[1][:7])
    c.check("resolving-merge-on-task-branch", bool(on_branch),
            "merge commit(s) on the task branch: %s" % ", ".join(on_branch) if on_branch else
            "no plan-side merge whose task-side parent is itself a merge")

    ec.assert_stopped(s, c, ["1", "2"])
    return c.finish()


if __name__ == "__main__":
    sys.exit(main())
