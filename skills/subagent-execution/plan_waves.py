"""Turn an implementation plan into dispatch waves (run by ./plan-waves).

Usage: python3 -I plan_waves.py <plan-file>
       python3 -I plan_waves.py --format <plan-file>

Exit 0: one stdout line per wave, `wave <k>: <id>, <id>, ...`, ids spelled as
their headings spell them (`T3`, or `Task 3` for Task-style headings), plan
order within a wave. Wave 1 is every task whose Depends on is nothing; wave
k+1 is every task whose dependencies are all in waves <= k.

Exit 2: one stderr line per problem, every problem found in one run, nothing
on stdout. Each line starts `plan-waves: <kind>:`, kind one of usage, file,
unclosed-fence, heading-in-fence, no-tasks, duplicate, no-depends, two-depends, bad-depends,
unknown-id, cycle (and python, from the launcher). The orchestrator relies on
these kinds.

--format: print the plan's format, `0.8.0` or `pre-0.8.0`, and exit 0 (usage
and file problems exit 2 as above). A plan is 0.8.0 when it has a
`**Touches:**` line (any indentation, bulleted or not) or a `Parallel safety`
heading (any level, any case) anywhere, fenced or not; both arrived in 0.8.0.
Fences are not consulted, so a 0.8.0 plan whose markers a broken fence
swallowed still reaches the wave script and its fence problems (re-review 1,
R3). Anything else is pre-0.8.0, whatever its Depends on lines say: older
plans often have Depends on lines that the wave grammar rejects.

Grammar:
- Task headings start in column 0: `## T<id> <sep> ...`, `## Task <id> <sep> ...`
  (sep one of em dash, en dash, hyphen, colon, with optional spaces before
  it) and `### Task <id> ...`, where
  <id> is digits then optional letters. `T3`, `Task 3` and `3` are the same
  task; ids compare case-insensitively. A task's body runs to the next task
  heading (other headings don't end it).
- Each body has exactly one `**Depends on:**` line, also in column 0:
  `nothing`/`none` (any case), or comma-separated ids; `nothing`, `none` and
  each id may take a parenthesised reason that holds no parentheses. One trailing period is ignored (`nothing.`,
  `T1 (reason).`).
- ``` and ~~~ fenced blocks are skipped. A fence closes only on a line made of
  the opener's character, at least as many as the opener. A fence still open
  at the end of the file, with a task heading after its opener, is an
  unclosed-fence problem: those headings would otherwise vanish silently.
- Any other fence holding a column-0 task heading or a column-0
  `**Depends on:**` line is a heading-in-fence problem. A fence left open
  usually pairs with a later code block's closer and swallows the tasks in
  between; this catches that. The trade-off: a plan can't quote a task heading
  or a Depends on line in column 0 inside a fence. That is rare (none of 65
  real plans do it); indent the quoted lines instead.
- Ids compare as written apart from case: `T01` and `T1` are different tasks.
- CRLF and LF files parse the same.

Never writes files. Stdlib only.
"""

import re
import sys

ID = r"[0-9]+[A-Za-z]*"
HEADINGS = [
    # (regex, spelling prefix)
    (re.compile(r"^## T(" + ID + r")[ \t]*(?:—|–|-|:)"), "T"),
    (re.compile(r"^## Task (" + ID + r")[ \t]*(?:—|–|-|:)"), "Task "),
    (re.compile(r"^### Task (" + ID + r")(?=[\s:.—–-]|$)"), "Task "),
]
NOTHING = re.compile(r"^(?:nothing|none)\s*(?:\([^()]*\))?$", re.IGNORECASE)
DEPENDS = re.compile(r"^\*\*Depends on:\*\*(.*)$")
DEP_ITEM = re.compile(
    r"^\s*(?:Task\s+|T)?(" + ID + r")\s*(?:\([^()]*\))?\s*$", re.IGNORECASE
)
FENCE_OPEN = re.compile(r"^\s*(`{3,}|~{3,})")
TOUCHES = re.compile(r"^\s*(?:[-*+]\s+)?\*\*Touches:\*\*")
PARALLEL_SAFETY = re.compile(r"^#{1,6}\s+Parallel safety\b", re.IGNORECASE)


def problem(problems, kind, message):
    problems.append("plan-waves: %s: %s" % (kind, message))


def read_lines(path, problems):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        problem(problems, "file", "no such file: %s" % path)
        return None
    except IsADirectoryError:
        problem(problems, "file", "not a file: %s" % path)
        return None
    except OSError as e:
        problem(problems, "file", "cannot read %s: %s" % (path, e.strerror or e))
        return None
    text = data.decode("utf-8", errors="replace")
    if text.startswith("﻿"):
        text = text[1:]
    return [line[:-1] if line.endswith("\r") else line for line in text.split("\n")]


def unfenced(lines, fences=None):
    """Yield (line_number, line) for lines outside fenced code blocks.

    When `fences` is a list, each fence is appended to it as
    (opener line, closer line or None when never closed, inside line numbers).
    """
    fence = None  # (char, length, opener line, inside lines) while inside a fence
    for n, line in enumerate(lines, 1):
        if fence is not None:
            char, length, opener, inside = fence
            stripped = line.strip()
            if len(stripped) >= length and stripped == char * len(stripped):
                if fences is not None:
                    fences.append((opener, n, inside))
                fence = None
            else:
                inside.append(n)
            continue
        m = FENCE_OPEN.match(line)
        if m:
            run = m.group(1)
            # A backtick fence's info string may not hold a backtick, so
            # ```x``` is inline code, not a fence.
            if run[0] == "`" and "`" in line[m.end():]:
                yield n, line
                continue
            fence = (run[0], len(run), n, [])
            continue
        yield n, line
    if fence is not None and fences is not None:
        fences.append((fence[2], None, fence[3]))


def heading_id(line):
    """(spelling, id) when the line is a task heading, else None."""
    for regex, prefix in HEADINGS:
        m = regex.match(line)
        if m:
            return prefix + m.group(1), m.group(1)
    return None


def parse_tasks(lines, problems):
    """Return tasks in plan order: dicts with name, key, line, depends."""
    tasks, fences = [], []
    for n, line in unfenced(lines, fences):
        found = heading_id(line)
        if found:
            spelling, ident = found
            tasks.append({"name": spelling, "key": ident.lower(), "line": n, "depends": []})
            continue
        m = DEPENDS.match(line)
        if m and tasks:
            tasks[-1]["depends"].append((n, m.group(1)))
    for opener, closer, inside in fences:
        hidden = [(n, heading_id(lines[n - 1])[0]) for n in inside if heading_id(lines[n - 1])]
        if closer is None and hidden:
            problem(problems, "unclosed-fence",
                    "the fence opened at line %d is never closed, hiding task heading(s) %s"
                    % (opener, ", ".join("%s (line %d)" % (name, n) for n, name in hidden)))
            continue
        held = sorted(hidden + [(n, "**Depends on:**") for n in inside if DEPENDS.match(lines[n - 1])])
        if held:
            problem(problems, "heading-in-fence",
                    "the fence opened at line %d and %s holds %s; a fence left open pairs with a later "
                    "closer and hides the tasks in between (indent a quoted line to keep it)"
                    % (opener, "closed at line %d" % closer if closer else "never closed",
                       ", ".join("%s (line %d)" % (name, n) for n, name in held)))
    return tasks


def plan_format(lines):
    """`0.8.0` when the plan has a Touches line or a Parallel safety heading,
    fenced or not."""
    for line in lines:
        if TOUCHES.match(line) or PARALLEL_SAFETY.match(line):
            return "0.8.0"
    return "pre-0.8.0"


def parse_depends(value):
    """Return (keys, bad_items) for a Depends on value."""
    value = value.strip()
    # Plans often end the line as a sentence; one trailing period is ignored.
    if value.endswith("."):
        value = value[:-1].rstrip()
    if NOTHING.match(value):
        return [], []
    keys, bad = [], []
    for item in value.split(","):
        m = DEP_ITEM.match(item)
        if m:
            keys.append(m.group(1).lower())
        else:
            bad.append(item.strip() or "(empty)")
    return keys, bad


def find_cycles(nodes, edges):
    """Strongly connected components that are cycles, among `nodes` (ordered)."""
    def reach(start):
        seen, stack = set(), [start]
        while stack:
            for nxt in edges[stack.pop()]:
                if nxt not in seen:
                    seen.add(nxt)
                    stack.append(nxt)
        return seen

    reachable = {v: reach(v) for v in nodes}
    cycles, placed = [], set()
    for v in nodes:
        if v in placed or v not in reachable[v]:
            continue
        members = [u for u in nodes if u in reachable[v] and v in reachable[u]]
        placed.update(members)
        cycles.append(members)
    return cycles


def main(argv):
    problems = []
    fmt = bool(argv) and argv[0] == "--format"
    if fmt:
        argv = argv[1:]
    if len(argv) != 1:
        problem(problems, "usage", "plan-waves <plan-file>, or plan-waves --format <plan-file> (got %d arguments)" % len(argv))
        return problems, None
    path = argv[0]
    lines = read_lines(path, problems)
    if lines is None:
        return problems, None
    if fmt:
        return [], [plan_format(lines)]
    tasks = parse_tasks(lines, problems)
    if not tasks:
        problem(problems, "no-tasks",
                "no task headings (## T<id> -, ## Task <id> -, ### Task <id>) in %s" % path)
        return problems, None

    # Duplicates: one line per id, naming every heading line.
    order, by_key = [], {}
    for t in tasks:
        if t["key"] not in by_key:
            order.append(t["key"])
            by_key[t["key"]] = []
        by_key[t["key"]].append(t)
    for key in order:
        same = by_key[key]
        if len(same) > 1:
            problem(problems, "duplicate", "task %s appears %d times (lines %s)" % (
                same[0]["name"], len(same), ", ".join(str(t["line"]) for t in same)))

    # Edges keyed by normalized id; duplicates' dependencies are merged so a
    # cycle through either copy is still reported.
    name = {key: by_key[key][0]["name"] for key in order}
    edges = {key: set() for key in order}
    for t in tasks:
        if not t["depends"]:
            problem(problems, "no-depends",
                    "%s (line %d) has no **Depends on:** line" % (t["name"], t["line"]))
            continue
        if len(t["depends"]) > 1:
            problem(problems, "two-depends", "%s (line %d) has %d **Depends on:** lines (lines %s)" % (
                t["name"], t["line"], len(t["depends"]),
                ", ".join(str(n) for n, _ in t["depends"])))
        for n, value in t["depends"]:
            keys, bad = parse_depends(value)
            if bad:
                problem(problems, "bad-depends",
                        "%s line %d: cannot parse %s (want nothing, none, or ids like T1 (reason), T3; any may take a (reason))"
                        % (t["name"], n, ", ".join(repr(b) for b in bad)))
            for k in keys:
                if k in edges:
                    edges[t["key"]].add(k)
                else:
                    problem(problems, "unknown-id",
                            "%s line %d depends on unknown task %s" % (t["name"], n, k))

    # Layering: a task's wave is one more than its deepest dependency's.
    wave = {}
    progress = True
    while progress:
        progress = False
        for key in order:
            if key not in wave and all(d in wave for d in edges[key]):
                wave[key] = 1 + max((wave[d] for d in edges[key]), default=0)
                progress = True
    stuck = [key for key in order if key not in wave]
    for members in find_cycles(stuck, edges):
        if len(members) == 1:
            problem(problems, "cycle", "%s depends on itself" % name[members[0]])
        else:
            problem(problems, "cycle",
                    "%s depend on each other" % ", ".join(name[k] for k in members))

    if problems:
        return problems, None
    out = []
    for k in range(1, max(wave.values()) + 1):
        out.append("wave %d: %s" % (k, ", ".join(name[key] for key in order if wave[key] == k)))
    return [], out


if __name__ == "__main__":
    errors, output = main(sys.argv[1:])
    if errors:
        sys.stderr.write("\n".join(errors) + "\n")
        sys.exit(2)
    sys.stdout.write("\n".join(output) + "\n")
