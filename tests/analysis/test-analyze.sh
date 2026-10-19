#!/usr/bin/env bash
# Tests for scripts/analyze_delegation.py (multi-harness delegation analysis).
#
#   * `--harness claude` is byte-identical to the pre-multi-harness script
#     (pinned: `git show 8419058:scripts/analyze_delegation.py`) on the Claude
#     fixture set, with --since, and with a missing --projects-dir;
#   * optional: the same identity on a snapshot copy of ~/.claude/projects
#     (ANALYZE_REAL=1; the copy is about 1 GB, so not on every run);
#   * the default (`all`) layout: harness column, date-sorted rows, per-harness
#     summary lines, the `all` line and the legend, in their exact format;
#   * --harness parsing: comma lists, canonical order, unknown names rejected.
#
# Expected values come from tests/analysis/fixtures/README.md (hand-derived).
# Usage: tests/analysis/test-analyze.sh   (needs python3 and git)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE_SHA=8419058
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -C "$REPO" show "$BASELINE_SHA:scripts/analyze_delegation.py" > "$WORK/old.py" \
  || { echo "FAIL: cannot read the baseline script at $BASELINE_SHA"; exit 1; }

if [ "${ANALYZE_REAL:-}" = 1 ] && [ -d "$HOME/.claude/projects" ]; then
  # Live logs change between two runs; compare both scripts on a frozen copy.
  cp -a --reflink=auto "$HOME/.claude/projects" "$WORK/real-projects"
fi

exec python3 - "$REPO" "$WORK" <<'PY'
import os, re, subprocess, sys

repo, work = sys.argv[1], sys.argv[2]
new = os.path.join(repo, "scripts", "analyze_delegation.py")
old = os.path.join(work, "old.py")
fixtures = os.path.join(repo, "tests", "analysis", "fixtures", "claude", "projects")
# Hermetic locations for the other harnesses: none of them exists.
nowhere = ["--codex-home", os.path.join(work, "no-codex"), "--opencode-db", os.path.join(work, "no-oc.db"),
           "--pi-sessions", os.path.join(work, "no-pi")]
failures = []
passed = 0


def run(script, *args):
    return subprocess.run([sys.executable, script, *args], capture_output=True, cwd=work)


def check(name, cond, detail=""):
    global passed
    if cond:
        passed += 1
        print(f"ok   {name}")
    else:
        failures.append(name)
        print(f"FAIL {name}\n{detail}")


def identity(name, *args):
    a, b = run(old, *args), run(new, "--harness", "claude", *args)
    check(f"{name}: old script ran", a.returncode == 0, a.stderr.decode())
    check(f"{name}: byte-identical to the old script", a.returncode == b.returncode and a.stdout == b.stdout and b.stderr == b"",
          f"--- old\n{a.stdout.decode()}\n--- new (rc {b.returncode})\n{b.stdout.decode()}{b.stderr.decode()}")
    return b.stdout.decode()


LEGEND = ("approval-gap column: user turns between design-spec and first implementation action ('-' = no design-spec; "
          "0 with an AskUserQuestion approval still counts as approved — check the ASK text)")
HEADER_TAIL = ("project                            main       usr   mainOut   subOut sub% mEdit mBashW sEdit  $main  $sub apprv"
               "  sub-models | skills | spawns")

# --- byte identity, --harness claude -------------------------------------------------
out = identity("claude fixtures", "--projects-dir", fixtures)
# Guard against a vacuous identity (an empty fixture read prints the same on both).
check("claude fixtures: rows in path order, not date order",
      [l[:10] for l in out.splitlines()[1:4]] == ["2026-10-12", "2026-10-03", "2026-10-07"], out)
check("claude fixtures: legacy summary", "\nsessions: 3 (all dates)\n" in out and "est. spend: main-loop $4  subagents $2\n" in out, out)

out = identity("claude fixtures --since", "--projects-dir", fixtures, "--since", "2026-10-05")
check("claude fixtures --since: b2 dropped", "sessions: 2 (since 2026-10-05)" in out and "2026-10-03" not in out, out)

missing = os.path.join(work, "no-projects")
out = identity("missing --projects-dir", "--projects-dir", missing)
check("missing --projects-dir: header, sessions 0, no note",
      out == f"date       {HEADER_TAIL}\n\nsessions: 0 (all dates)\n\n"
             "file edits: main-loop Edit/Write 0  main-loop Bash writes 0  subagent Edit/Write 0\n"
             "est. spend: main-loop $0  subagents $0\nAgent spawn `model` param: {}\n"
             "subagent output tokens by actual model: {}\n" + LEGEND + "\n", out)

real = os.path.join(work, "real-projects")
if os.path.isdir(real):
    out = identity("real ~/.claude/projects snapshot", "--projects-dir", real)
    check("real snapshot: has sessions", re.search(r"\nsessions: [1-9]", out) is not None, out[-2000:])
else:
    print("skip real ~/.claude/projects snapshot (set ANALYZE_REAL=1; needs ~/.claude/projects)")

# --- multi-harness layout ---------------------------------------------------------------
ROW_B2 = ("2026-10-03 cc fixture-alpha                      gpt-unknown   1       700        0   0%     0      0     0"
          "   0.00  0.00     0                       | design-spec,fp:implementation-plan | ")
ROW_A1 = ("2026-10-12 cc fixture-alpha                      sonnet-5     2     2,000        0   0%     0      0     0"
          "   0.12  0.00     -                       | fp:verify-done,sp:brainstorming | ")
# c3's two printed sub-models come from a three-way tie, so they follow the
# filesystem's glob order (see the fixture README); everything else is pinned.
ROW_C3 = re.compile(re.escape("2026-10-07 cc fixture-beta/feat-x                opus-5       4    57,000    9,000  14%     2      1     3"
                              "   4.25  2.10     2  ") + r"\S+:1 \S+:1"
                    + re.escape(" | fp:design-spec | implementer@sonnetx1 reviewerx1 explorerx1") + "$")
# Summary: main 59,700 sub 9,000; spend 4.37 + 2.095 = 6.465, which is the double
# 6.4649999... and prints as 6.46.
CC = "cc sessions 3  out main 59,700 sub 9,000 (13.1% sub)  edits main 2 shell 1 sub 3  spend $6.46  spawns {'sonnet': 1, '(unset)': 2}"
ALL = "all" + CC[2:]
SUBMODELS = "subagent output tokens by actual model: {'sonnet-5': '6,000', 'haiku-4-5-20251001': '2,000', 'opus-5': '1,000'}"

for label, extra in (("default harness", []), ("--harness all", ["--harness", "all"])):
    r = run(new, "--projects-dir", fixtures, *nowhere, *extra)
    out = r.stdout.decode(); lines = out.split("\n")
    check(f"{label}: exit 0", r.returncode == 0 and r.stderr == b"", r.stderr.decode())
    check(f"{label}: header has the h column after date", lines[0] == f"date       h  {HEADER_TAIL}", lines[0])
    check(f"{label}: rows sorted by date", lines[1] == ROW_B2 and ROW_C3.match(lines[2]) is not None and lines[3] == ROW_A1,
          "\n".join(lines[1:4]))
    check(f"{label}: blank line, then the cc summary line", lines[4] == "" and lines[5] == CC, "\n".join(lines[4:6]))
    check(f"{label}: one note per harness without logs, in order",
          [l.split(" ", 1)[0] for l in lines[6:9]] == ["cx", "oc", "pi"] and all(l[3:9] == "note: " for l in lines[6:9]),
          "\n".join(lines[6:9]))
    check(f"{label}: all line, sub-model line, legend, end", lines[9:] == [ALL, SUBMODELS, LEGEND, ""], "\n".join(lines[9:]))

r = run(new, "--projects-dir", fixtures, *nowhere, "--since", "2026-10-05")
lines = r.stdout.decode().split("\n")
check("all --since: b2 dropped, cc line recounted",
      [l[:10] for l in lines[1:3]] == ["2026-10-07", "2026-10-12"] and lines[3] == ""
      and lines[4] == "cc sessions 2  out main 59,000 sub 9,000 (13.2% sub)  edits main 2 shell 1 sub 3  spend $6.46  spawns {'sonnet': 1, '(unset)': 2}",
      r.stdout.decode())

r = run(new, "--projects-dir", missing, *nowhere)
lines = r.stdout.decode().split("\n")
check("all with no claude logs: note instead of a cc line, all line has n/a spend",
      lines[1:3] == ["", f"cc note: no claude logs at {missing}"]
      and "all sessions 0  out main 0 sub 0 (-% sub)  edits main 0 shell 0 sub 0  spend n/a  spawns {}" in lines,
      r.stdout.decode())

# --- cost not recorded (Codex logs no price): printer, on records built here ---------------
import collections, contextlib, importlib.util, io
spec = importlib.util.spec_from_file_location("analyze_delegation", new)
ad = importlib.util.module_from_spec(spec); spec.loader.exec_module(ad)


def rec(h, ts, cost, subs=(), model="m"):
    return dict(harness=h, ts=ts, proj="p", models=collections.Counter({model: 1}), user_turns=1, out=100, cost=cost,
                skills=[], spawns=[], edits=0, bash_writes=0, seq=[], subs=[dict(models=collections.Counter({"s": 1}),
                out=50, cost=c, edits=0) for c in subs])


# Pi sub costs 2.06 + 0.01 + 0.025 = 2.095: a plain left-to-right float sum gives
# 2.0949999... (prints 2.09); the exact sum is the double 2.0950000... (prints 2.10).
# Spend 1.25 + 2.095 = 3.345 likewise prints 3.35 only when summed exactly.
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    ad.print_multi([rec("cx", "2026-10-15", None, [None]),
                    rec("pi", "2026-10-14", 1.25, [2.06, 0.01, 0.025], model="deepseek/deepseek-v4-flash")],
                   {}, ["codex", "pi"])
lines = buf.getvalue().split("\n")
check("cost None: '-' cells; recorded cost: 2 decimals, summed exactly",
      lines[1].split()[11:13] == ["1.25", "2.10"] and lines[2].split()[11:13] == ["-", "-"], buf.getvalue())
check("cost None: spend n/a for cx, $ for pi, all sums only recorded costs",
      " spend n/a " in lines[4] and lines[4].startswith("cx sessions 1 ") and " spend $3.35 " in lines[5]
      and lines[6].startswith("all sessions 2 ") and " spend $3.35 " in lines[6], buf.getvalue())
check("main model column drops the provider prefix", lines[1].split()[3] == "deepseek-v4-flash", buf.getvalue())

# --- --harness parsing ---------------------------------------------------------------------
r = run(new, "--projects-dir", fixtures, *nowhere, "--harness", "pi,claude")
lines = r.stdout.decode().split("\n")
check("comma list: multi layout, harnesses in canonical order",
      r.returncode == 0 and lines[0].startswith("date       h  ") and lines[5] == CC and lines[6].startswith("pi note: ")
      and lines[7] == ALL, r.stdout.decode() + r.stderr.decode())

r = run(new, "--projects-dir", fixtures, "--harness", "claude,claude")
check("claude listed twice is still claude-only", r.stdout == run(old, "--projects-dir", fixtures).stdout, r.stdout.decode())

for bad in ("bogus", "claude,bogus", "claude,", "Claude"):
    r = run(new, "--projects-dir", fixtures, "--harness", bad)
    err = r.stderr.decode()
    check(f"--harness {bad!r}: argparse error", r.returncode == 2 and r.stdout == b""
          and "argument --harness: unknown harness" in err and "usage:" in err, f"rc {r.returncode}\n{err}")

print(f"\n{passed} passed, {len(failures)} failed")
sys.exit(1 if failures else 0)
PY
