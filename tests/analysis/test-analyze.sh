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
#   * --harness parsing: comma lists, canonical order, unknown names rejected;
#   * the Codex reader: exact record dicts and printed rows for every Codex
#     fixture, --since by UTC start date, and rollouts written by the test for
#     the rules the real fixtures do not exercise;
#   * the OpenCode reader: exact record dicts and printed rows for every OpenCode
#     fixture session (both SQL files loaded into a temp db), --since, the
#     read-only WAL-safe open (and its immutable fallback), seq order without the
#     index, and the notes for a missing db, a db without session_v2 and a non-db;
#   * the Pi reader: exact record dicts and printed rows for both layouts (flat
#     --session-dir, default --<cwd>--, and both in one dir), child linkage by
#     entry and by directory, depth-2 roll-up, orphans, --since, approval results
#     as gap events, and sessions written by the test for the remaining rules.
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
# The multi-harness layout: an 18-wide main model, 10-wide token columns and cost columns sized for 2 decimals.
HEADER_MULTI = ("date       h  project                            main               usr    mainOut     subOut sub% mEdit mBashW sEdit"
                "     $main     $sub apprv  sub-models | skills | spawns")

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
ROW_B2 = ("2026-10-03 cc fixture-alpha                      gpt-unknown          1        700          0   0%     0      0     0"
          "      0.00     0.00     0                       | design-spec,fp:implementation-plan | ")
ROW_A1 = ("2026-10-12 cc fixture-alpha                      sonnet-5             2      2,000          0   0%     0      0     0"
          "      0.12     0.00     -                       | fp:verify-done,sp:brainstorming | ")
# c3's two printed sub-models come from a three-way tie, so they follow the
# filesystem's glob order (see the fixture README); everything else is pinned.
ROW_C3 = re.compile(re.escape("2026-10-07 cc fixture-beta/feat-x                opus-5               4     57,000      9,000  14%     2      1     3"
                              "      4.25     2.10     2  ") + r"\S+:1 \S+:1"
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
    check(f"{label}: header has the h column after date", lines[0] == HEADER_MULTI, lines[0])
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

# Widths: a model id longer than 18 is cut with `..`; a 5-digit cost keeps its 2 decimals in the column;
# sub-model cells drop provider prefixes.
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    ad.print_multi([dict(rec("cc", "2026-10-13", 10291.234, [2.5], model="openrouter/some-very-long-model-id-x"),
                         subs=[dict(models=collections.Counter({"qwen/qwen3.6-flash": 2}), out=50, cost=2.5, edits=0)])],
                   {}, ["claude"])
lines = buf.getvalue().split("\n")
check("multi widths: long main id cut to 18, 5-digit cost aligned, sub-model prefix dropped",
      lines[1] == "2026-10-13 cc p                                  some-very-long-m..   1        100         50  33%     0      0     0"
                  "  10291.23     2.50     -  qwen3.6-flash:2      |  | "
      and lines[1].index("10291.23") + 8 == HEADER_MULTI.index("$main") + 5, buf.getvalue())

# Token columns: mainOut and subOut are 10 wide in the multi layout, so 7- and 8-digit counts
# (1,234,567 and 12,345,678) end at their header's right edge and the columns after them stay put.
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    ad.print_multi([dict(rec("cc", "2026-10-13", 1.0, [2.0]), out=12345678,
                         subs=[dict(models=collections.Counter({"s": 1}), out=1234567, cost=2.0, edits=0)]),
                    dict(rec("cc", "2026-10-14", 1.0, [2.0]), out=1234567,
                         subs=[dict(models=collections.Counter({"s": 1}), out=12345678, cost=2.0, edits=0)])],
                   {}, ["claude"])
lines = buf.getvalue().split("\n")
check("multi widths: 7- and 8-digit mainOut/subOut keep every column aligned",
      lines[0] == HEADER_MULTI
      and lines[1] == "2026-10-13 cc p                                  m                    1 12,345,678  1,234,567   9%     0      0     0"
                      "      1.00     2.00     -  s:1                  |  | "
      and lines[2] == "2026-10-14 cc p                                  m                    1  1,234,567 12,345,678  91%     0      0     0"
                      "      1.00     2.00     -  s:1                  |  | "
      and all(l.index(v) + len(v) == HEADER_MULTI.index(col) + len(col)
              for l, vs in ((lines[1], ("12,345,678", "1,234,567")), (lines[2], ("1,234,567", "12,345,678")))
              for v, col in zip(vs, ("mainOut", "subOut"))), buf.getvalue())

# --- Codex reader ---------------------------------------------------------------------------
# Expected values: tests/analysis/fixtures/README.md (Codex table), hand-derived, with the
# orchestrator rulings applied (agent_type -> role; edits/spawns count attempts).
import argparse, json, shutil
codex_home = os.path.join(repo, "tests", "analysis", "fixtures", "codex")
PH, IMP, REV = "placeholder text", "implement placeholder", "review placeholder"


def sub(model, out, edits, n=1):
    return dict(models={model: n}, out=out, cost=None, edits=edits)


def cx(ts, proj, models, usr, out, skills, spawns, edits, bw, seq, subs):
    return dict(harness="cx", ts=ts, proj=proj, models=models, user_turns=usr, out=out, cost=None, skills=skills,
                spawns=[dict(role=r, model=m) for r, m in spawns], edits=edits, bash_writes=bw, seq=seq, subs=subs)


L, T, S6 = "gpt-5.6-luna", "gpt-5.6-terra", "gpt-6-luna"
CX_EXPECTED = [
    # 67db (v2): agent_type fp-implementer -> implementer; no model passed, so the seat's config pins it:
    # `seat`, not (unset). Depth-2 grandchild 85ec rolled up.
    cx("2026-10-15", "codex-repo", {S6: 1}, 1, 264, [], [("implementer", "seat")], 0, 0, [("user", IMP)],
       [sub(T, 344, 0), sub(T, 19, 0)]),
    # 88c2: one FileChange (code file), request_user_input -> ask.
    cx("2026-10-15", "codex-repo", {S6: 1}, 1, 157, [], [], 1, 0,
       [("user", IMP), ("edit", "/fixture/codex-repo/f6.txt"), ("ask", "")], []),
    # c958 (v1): skills from sed reads; spawns from CollabAgentToolCall, roles from the children's first
    # UserMessage (heuristic: "implement…" / "placeholder text"); one apply_patch attempt with no
    # FileChange counts as an edit (attempts), likewise in child eaed.
    cx("2026-10-15", "codex2-repo", {L: 1}, 1, 960, ["fablepowers:workflow", "fablepowers:subagent-execution"],
       [("implementer", L), ("other", L)], 1, 0,
       [("user", REV), ("skill", "workflow"), ("skill", "subagent-execution"), ("edit", "")],
       [sub(L, 218, 1), sub(L, 5, 0)]),
    # 3129 (v1): the child's first UserMessage starts `fablepowers-seat: reviewer`.
    cx("2026-10-15", "codex-port-t0-repo", {L: 1}, 1, 339, [], [("reviewer", L)], 1, 0,
       [("user", REV), ("edit", "/fixture/codex-port-t0-repo/docs/specs/f6.md")], [sub(L, 6, 0)]),
    # 0374 (compaction): out 103 from thread_token_usage (the last token_count total is 27);
    # `$fablepowers:approve` selected twice; the second UserMessage has only a skill item.
    cx("2026-10-15", "codex-port-t0-repo", {S6: 5}, 3, 103, ["fablepowers:approve", "fablepowers:approve"], [], 0, 0,
       [("user", PH + " "), ("skill", "approve"), ("user", ""), ("skill", "approve"), ("user", PH)], []),
    # 3524 (v2): 5 spawns from task names; implementer_t1 has no child rollout.
    cx("2026-10-17", "codex-r1", {S6: 4}, 4, 4026,
       ["fablepowers:approve", "fablepowers:implementation-plan", "fablepowers:subagent-execution",
        "fablepowers:behavioral-testing", "fablepowers:integration-review"],
       [("implementer", S6), ("reviewer", S6), ("reviewer", S6), ("implementer", S6), ("implementer", S6)], 3, 0,
       [("user", REV), ("edit", "/fixture/codex-r1/docs/specs/f6.md"), ("user", REV),
        ("user", "$fablepowers:approve\n" + PH), ("skill", "approve"), ("skill", "implementation-plan"),
        ("skill", "subagent-execution"), ("skill", "behavioral-testing"), ("edit", "/fixture/codex-r1/docs/plans/f9.md"),
        ("edit", "/fixture/codex-r1/docs/plans/f9.md"), ("skill", "integration-review"), ("user", IMP)],
       [sub(S6, 6, 0), sub(S6, 1143, 0), sub(S6, 835, 1), sub(S6, 142, 0)]),
    # synthetic root: gap 3; the catalogue stub is absent here and the truncated last line is skipped.
    cx("2026-10-18", "cx-synth", {"gpt-6-sol": 1}, 5, 600, ["fablepowers:design-spec"], [("reviewer", S6)], 2, 1,
       [("user", PH), ("skill", "design-spec"), ("user", PH), ("ask", ""), ("user", PH),
        ("edit", "/fixture/cx-synth/docs/specs/f1.md"), ("user", PH), ("edit", "bash-write"),
        ("edit", "/fixture/cx-synth/src/f2.py"), ("user", PH)],
       [sub(S6, 450, 1)]),
    # orphan: parent …ff is missing.
    cx("2026-10-18", "(orphan) cx-synth", {}, 0, 0, [], [], 0, 0, [], [sub(S6, 70, 0)]),
]


def plain(r):
    r = dict(r, models=dict(r["models"]), seq=[tuple(x) for x in r["seq"]],
             subs=[dict(x, models=dict(x["models"])) for x in r["subs"]])
    return r


def read_cx(home, since=None):
    return ad.read_codex(argparse.Namespace(codex_home=home, since=since))


got, note = read_cx(codex_home)
check("codex: 7 roots + 1 orphan record, in path order", len(got) == len(CX_EXPECTED), f"{len(got)} records")
for i, (g, e) in enumerate(zip(got, CX_EXPECTED)):
    g = plain(g)
    check(f"codex record {i} ({e['proj']} {e['ts']}): exact dict", g == e,
          "\n".join(f"  {k}: got {g.get(k)!r}\n  {' ' * len(k)}  exp {e[k]!r}" for k in e if g.get(k) != e[k]))
check("codex: .zst rollout skipped with a note", note == "1 .jsonl.zst rollout(s) skipped (zstd is not in the stdlib)", note)
check("codex: approval gap 3 on the synthetic root, '-' elsewhere",
      [ad.approval_gap(r["seq"]) for r in got] == [None] * 6 + [3, None], [ad.approval_gap(r["seq"]) for r in got])

CX_ROWS = [
    "2026-10-15 cx codex-repo                         gpt-6-luna           1        264        363  58%     0      0     0         -        -     -  gpt-5.6-terra:2      |  | implementer@seatx1",
    "2026-10-15 cx codex-repo                         gpt-6-luna           1        157          0   0%     1      0     0         -        -     -                       |  | ",
    "2026-10-15 cx codex2-repo                        gpt-5.6-luna         1        960        223  19%     1      0     1         -        -     -  gpt-5.6-luna:2       | fp:workflow,fp:subagent-execution | implementer@gpt-5.6-lunax1 other@gpt-5.6-lunax1",
    "2026-10-15 cx codex-port-t0-repo                 gpt-5.6-luna         1        339          6   2%     1      0     0         -        -     -  gpt-5.6-luna:1       |  | reviewer@gpt-5.6-lunax1",
    "2026-10-15 cx codex-port-t0-repo                 gpt-6-luna           3        103          0   0%     0      0     0         -        -     -                       | fp:approve | ",
    "2026-10-17 cx codex-r1                           gpt-6-luna           4      4,026      2,126  35%     3      0     1         -        -     -  gpt-6-luna:4         | fp:approve,fp:implementation-plan,fp:subagent-execution,fp:behavioral-testing,fp:integration-review | implementer@gpt-6-lunax3 reviewer@gpt-6-lunax2",
    "2026-10-18 cx cx-synth                           gpt-6-sol            5        600        450  43%     2      1     1         -        -     3  gpt-6-luna:1         | fp:design-spec | reviewer@gpt-6-lunax1",
    "2026-10-18 cx (orphan) cx-synth                  ?                    0          0         70 100%     0      0     0         -        -     -  gpt-6-luna:1         |  | ",
]
# main 264+157+960+339+103+4026+600 = 6,449; sub 363+223+6+2126+450+70 = 3,238 (33.4%);
# edits 1+1+1+3+2 = 8, shell 1, sub 1+1+1 = 3; spawns seat 1, gpt-5.6-luna 3, gpt-6-luna 6.
CX_SUM = ("sessions 8  out main 6,449 sub 3,238 (33.4% sub)  edits main 8 shell 1 sub 3  spend n/a  "
          "spawns {'seat': 1, 'gpt-5.6-luna': 3, 'gpt-6-luna': 6}")
r = run(new, "--harness", "codex", "--codex-home", codex_home)
lines = r.stdout.decode().split("\n")
check("codex printed: header and exact rows", r.returncode == 0 and r.stderr == b"" and lines[0] == HEADER_MULTI
      and lines[1:9] == CX_ROWS, "\n".join(f"got {a!r}\nexp {b!r}" for a, b in zip(lines[1:9], CX_ROWS) if a != b) + r.stderr.decode())
check("codex printed: summary, note, all line", lines[9:13] == ["", "cx " + CX_SUM, "cx note: " + note, "all " + CX_SUM],
      "\n".join(lines[9:13]))

# --since uses the session's UTC start date: 67db/88c2 live in the local-date dir 2026/10/14 but start 10-15.
got15, _ = read_cx(codex_home, "2026-10-15")
check("codex --since 2026-10-15 keeps sessions from the 10/14 directory", [plain(g) for g in got15] == CX_EXPECTED,
      [(g["ts"], g["proj"]) for g in got15])
got16, _ = read_cx(codex_home, "2026-10-16")
check("codex --since 2026-10-16: root 3524, synthetic root and the orphan", [plain(g) for g in got16] == CX_EXPECTED[5:],
      [(g["ts"], g["proj"]) for g in got16])

nocx = os.path.join(work, "no-codex")
check("codex: missing home -> no records and a note",
      read_cx(nocx) == ([], f"no codex logs at {os.path.join(nocx, 'sessions')}"), read_cx(nocx))

# --- Codex rules the real fixtures do not exercise: rollouts written here -------------------
def rollout(home, name, rid, records, parent=None, src=None, ts="2026-10-20T10:00:00.000Z"):
    d = os.path.join(home, "sessions", "2026", "10", "20"); os.makedirs(d, exist_ok=True)
    source = src if src is not None else (
        {"subagent": {"thread_spawn": {"parent_thread_id": parent, "depth": 1}}} if parent else "exec")
    with open(os.path.join(d, f"rollout-{name}-{rid}.jsonl"), "w") as fh:
        fh.write(json.dumps({"type": "session_meta", "payload": {"id": rid, "timestamp": ts, "cwd": "/w/repo/.claude/worktrees/wt",
                                                                 "source": source}}) + "\n")
        for t, p in records:
            fh.write(json.dumps({"type": t, "payload": p}) + "\n")


def item(it):
    return ("event_msg", {"type": "item_completed", "item": it})


synth = os.path.join(work, "cx-synth-home")
rollout(synth, "a", "r1", [
    ("turn_context", {"model": "m-main"}),
    # v1 exec: two JS spawns, one CollabAgentToolCall -> the second is an attempt with the JS literal's model
    # and seat. The first takes its role from child k1's `fablepowers-seat:` line (the prompt heuristic would
    # say reviewer for both).
    ("response_item", {"type": "custom_tool_call", "name": "exec", "call_id": "c1",
                       "input": 'tools.multi_agent_v1__spawn_agent({model: "m-a", message: "review it"});'
                                ' tools.multi_agent_v1__spawn_agent({model: "m-b", message: "fablepowers-seat: strict-implementer\\nreview notes"})'}),
    item({"type": "CollabAgentToolCall", "tool": "spawn_agent", "model": "m-a", "receiver_thread_ids": ["k1"]}),
    ("response_item", {"type": "custom_tool_call_output", "call_id": "c1"}),
    # a top-level apply_patch (older CLIs) that never ran: counted, with its file from the patch header.
    ("response_item", {"type": "custom_tool_call", "name": "apply_patch", "call_id": "c2",
                       "input": "*** Begin Patch\n*** Update File: docs/plans/p.md\n*** End Patch"}),
    ("response_item", {"type": "custom_tool_call_output", "call_id": "c2"}),
    # one FileChange with two files is two edits.
    item({"type": "FileChange", "changes": {"docs/specs/s.md": {"type": "add"}, "src/x.py": {"type": "update"}}}),
    # v2 spawn: the role comes from the child's agent_role when neither agent_type nor task_name names a seat.
    ("response_item", {"type": "function_call", "name": "spawn_agent", "call_id": "c3",
                       "arguments": json.dumps({"task_name": "probe", "message": "x"})}),
    # v2 spawn whose child never started: agent_type alone names the role.
    ("response_item", {"type": "function_call", "name": "spawn_agent", "call_id": "c4",
                       "arguments": json.dumps({"agent_type": "fp-strict-implementer", "task_name": "gone", "model": "m-d",
                                                "message": "review x"})}),
    # v2 spawns naming a fablepowers seat agent type without a model: `seat` (the agent type's config pins it);
    # an fp- agent type that is not a seat stays unset.
    ("response_item", {"type": "function_call", "name": "spawn_agent", "call_id": "c5",
                       "arguments": json.dumps({"agent_type": "fablepowers-reviewer", "task_name": "gone2", "message": "x"})}),
    ("response_item", {"type": "function_call", "name": "spawn_agent", "call_id": "c6",
                       "arguments": json.dumps({"agent_type": "fp-explorer", "task_name": "gone3", "message": "implement x"})}),
    # a shell read of a non-fablepowers SKILL.md is listed bare; `rg` over a SKILL.md is not a read.
    item({"type": "CommandExecution", "command": ["bash", "-lc", "rg foo /x/skills/other/SKILL.md; nl -ba /x/skills/mine/SKILL.md"]}),
    # no token_usage_record: fall back to the last token_count total.
    ("event_msg", {"type": "token_count", "info": {"total_token_usage": {"output_tokens": 5}}}),
    ("event_msg", {"type": "token_count", "info": {"total_token_usage": {"output_tokens": 9}}}),
])
rollout(synth, "b", "k1", [("turn_context", {"model": "m-a"}),
                           item({"type": "UserMessage", "content": [{"type": "text", "text": "fablepowers-seat: implementer\nreview it"}]})],
        parent="r1")
rollout(synth, "c", "k2", [("turn_context", {"model": "m-c"})], src={"subagent": {"thread_spawn": {
    "parent_thread_id": "r1", "agent_path": "/root/probe", "agent_role": "fp-reviewer"}}})
rollout(synth, "d", "k3", [], src={"subagent": "review"})
# not recognisable as a rollout: a first line that is not session_meta, and an empty file.
d_ = os.path.join(synth, "sessions", "2026", "10", "20")
with open(os.path.join(d_, "rollout-e-old.jsonl"), "w") as fh:
    fh.write(json.dumps({"type": "turn_context", "payload": {"model": "m-old"}}) + "\n")
open(os.path.join(d_, "rollout-f-empty.jsonl"), "w").close()
got, note = read_cx(synth)
g = plain(got[0]) if got else {}
check("codex synthetic: one root", len(got) == 1, [x["proj"] for x in got])
check("codex synthetic: spawns -- JS attempt without a CollabAgentToolCall (literal model + seat), child seat line, child agent_role, agent_type, seat agent_type without a model",
      g.get("spawns") == [dict(role="implementer", model="m-a"), dict(role="implementer", model="m-b"),
                          dict(role="reviewer", model=None), dict(role="implementer", model="m-d"),
                          dict(role="reviewer", model="seat"), dict(role="implementer", model=None)], g.get("spawns"))
check("codex synthetic: a top-level apply_patch attempt is an edit of the patched file; a FileChange counts its files",
      g.get("edits") == 3 and [x for x in g.get("seq", []) if x[0] == "edit"]
      == [("edit", "docs/plans/p.md"), ("edit", "docs/specs/s.md"), ("edit", "src/x.py")], g)
check("codex synthetic: only read verbs load a skill; non-fablepowers skills listed bare", g.get("skills") == ["mine"], g.get("skills"))
check("codex synthetic: out falls back to the last token_count total", g.get("out") == 9, g.get("out"))
check("codex synthetic: worktree cwd -> repo/worktree", g.get("proj") == "repo/wt", g.get("proj"))
check("codex synthetic: subs are k1 and k2", [s["models"] for s in g.get("subs", [])] == [{"m-a": 1}, {"m-c": 1}], g.get("subs"))
check("codex synthetic: a non-spawn subagent rollout and rollouts without session_meta are skipped with notes",
      note == "1 non-spawn subagent rollout(s) skipped; 2 rollout(s) skipped: no session_meta", note)

# --- OpenCode reader ------------------------------------------------------------------------
# Expected values: tests/analysis/fixtures/README.md (OpenCode table), hand-derived from the
# fixture rows, with the orchestrator rulings applied (attempts; every skill listed).
import sqlite3
oc_fx = os.path.join(repo, "tests", "analysis", "fixtures", "opencode")
OC_SQL = "".join(open(os.path.join(oc_fx, f)).read() for f in ("sanitised.sql", "synthetic.sql"))


def oc_db(path, wal=False):
    """Load both fixture files into a new db; with wal=True the connection stays open
    and nothing is checkpointed, so every row lives only in the -wal file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    con = sqlite3.connect(path)
    if wal:
        con.execute("PRAGMA journal_mode=WAL"); con.execute("PRAGMA wal_autocheckpoint=0")
    con.executescript(OC_SQL)
    if wal:
        return con
    con.close()


def read_oc(db, since=None):
    return ad.read_opencode(argparse.Namespace(opencode_db=db, since=since))


def osub(models, out, cost, edits):
    return dict(models=models, out=out, cost=cost, edits=edits)


def oc(ts, proj, models, usr, out, cost, skills, spawns, edits, bw, seq, subs):
    return dict(harness="oc", ts=ts, proj=proj, models=models, user_turns=usr, out=out, cost=cost, skills=skills,
                spawns=[dict(role=r, model=m) for r, m in spawns], edits=edits, bash_writes=bw, seq=seq, subs=subs)


BP, CJ, DS, MM = "big-pickle", "cat-jam-free", "deepseek-v4.1-flash-free", "mimo-v2.6-flash-free"
R1, R2 = "/fixture/opencode-t5-r1/", "/fixture/opencode-t5-r2/"
OC_EXPECTED = [
    # ec1f: out = 1,082 assistant + 481 compaction output + 360 reasoning; the compaction message is a model
    # call too (6 big-pickle messages). Both spawns pass a model, kept as requested.
    oc("2026-10-15", "opencode-scratch-repo", {BP: 6}, 3, 1923, 0.0, [],
       [("reviewer", "opencode/mimo-v2.6-flash-free"), ("implementer", "opencode/nemotron-3.5-lightning-free")], 0, 0,
       [("user", REV), ("user", "/compact\n" + PH), ("user", IMP)],
       [osub({MM: 1}, 224, 0.0, 0), osub({MM: 1}, 25, 0.0, 0)]),
    # ebd5: session_v2 says 795 + 383 = 1,178; messages say 1,160. `general` and the fp-seat-* test agents are
    # not fablepowers seats: role heuristic on "placeholder text" -> other, no model -> None. The `explore`
    # call at seq 71 carries input.sessionID: a resume, not a spawn. fp-probe:base is listed (ruling).
    oc("2026-10-16", "opencode-t0-repo", {BP: 10}, 2, 1160, 0.0, ["fp-probe:base"],
       [("other", None)] * 3, 2, 0,
       [("user", PH), ("edit", "/fixture/opencode-t0-repo/docs/specs/f1.md"),
        ("edit", "/fixture/opencode-t0-repo/docs/specs/f1.md"), ("skill", "base"), ("user", "explore placeholder")],
       [osub({BP: 3}, 80, 0.0, 1), osub({CJ: 1}, 26, 0.0, 0), osub({CJ: 1}, 25, 0.0, 0)]),
    # ebcf: 11 edit attempts (4 errored), 5 spawn attempts (1 errored), every one a seat -> `seat`.
    oc("2026-10-16", "opencode-t5-r1", {BP: 36}, 3, 7750, 0.0,
       ["fablepowers:implementation-plan", "fablepowers:subagent-execution", "fablepowers:integration-review",
        "fablepowers:verify-done"],
       [("implementer", "seat"), ("reviewer", "seat"), ("reviewer", "seat"), ("implementer", "seat"), ("reviewer", "seat")],
       11, 0,
       [("user", REV), ("edit", R1 + "docs/specs/f1.md"), ("user", PH), ("edit", R1 + "docs/plans/f3.md"),
        ("edit", R1 + "f2.py"), ("edit", R1 + "f4"), ("edit", R1 + "f5.json"), ("edit", R1 + "f6.json"),
        ("user", "/fablepowers:approve\n" + IMP), ("skill", "implementation-plan"), ("edit", R1 + "docs/plans/f8.md"),
        ("edit", R1 + "docs/plans/f8.md"), ("edit", R1 + "docs/plans/f8.md"), ("skill", "subagent-execution"),
        ("edit", R1 + "f10.md"), ("skill", "integration-review"), ("edit", R1 + "f10.md"), ("skill", "verify-done")],
       [osub({CJ: 1}, 29, 0.0, 0), osub({CJ: 5}, 898, 0.0, 1), osub({DS: 10}, 3813, 0.0, 4), osub({CJ: 4}, 651, 0.0, 0)]),
    # ebcec: the `synthetic` approval notice at seq 64 is not a user turn; `question` -> ask.
    oc("2026-10-16", "opencode-t5-r2", {BP: 34}, 2, 10215, 0.0,
       ["fablepowers:implementation-plan", "fablepowers:subagent-execution", "fablepowers:integration-review",
        "fablepowers:verify-done", "fablepowers:finishing-a-development-branch"],
       [("implementer", "seat"), ("reviewer", "seat"), ("implementer", "seat"), ("reviewer", "seat")], 7, 0,
       [("user", PH), ("edit", R2 + "docs/specs/f1.md"), ("ask", ""), ("user", IMP), ("edit", R2 + "docs/specs/f2.md"),
        ("skill", "implementation-plan"), ("edit", R2 + "docs/plans/f5.md"), ("edit", R2 + "docs/plans/f5.md"),
        ("edit", R2 + "docs/plans/f5.md"), ("skill", "subagent-execution"), ("edit", R2 + "f7.md"),
        ("skill", "integration-review"), ("edit", R2 + "f7.md"), ("skill", "verify-done"),
        ("skill", "finishing-a-development-branch")],
       [osub({CJ: 6}, 1812, 0.0, 1), osub({DS: 12}, 4121, 0.0, 5), osub({CJ: 5}, 1083, 0.0, 1)]),
    # synthetic root (rows inserted out of seq order): out 240 + 85 (session_v2 999 + 111), cost 1.25 + 0.5 +
    # 0.75 + 0 (session_v2 9.99). Spawns: seat, `general` with "review" in its description, a seat with a
    # requested model; the second implementer call resumes Impl001. Grandchild01 (depth 2) is rolled up.
    oc("2026-10-18", "oc-synth", {BP: 3, "gpt-oss-fixture": 1}, 4, 325, 2.5, ["fablepowers:design-spec"],
       [("implementer", "seat"), ("reviewer", None), ("reviewer", "opencode/cat-jam-free")], 2, 1,
       [("user", PH), ("skill", "design-spec"), ("user", PH), ("ask", ""), ("edit", "/fixture/oc-synth/docs/specs/f1.md"),
        ("user", "/fablepowers:approve"), ("edit", "/fixture/oc-synth/src/f2.py"), ("edit", "bash-write"), ("user", PH)],
       [osub({DS: 1}, 250, 1.5, 2), osub({BP: 1}, 30, 0.25, 1), osub({BP: 1}, 10, 0.0, 0), osub({CJ: 1}, 50, 1.0, 0)]),
    # orphan: Orphan00001's parent …MissingPar01 is absent.
    oc("2026-10-18", "(orphan) oc-synth", {}, 0, 0, 0.0, [], [], 0, 0, [], [osub({CJ: 1}, 60, 1.0, 0)]),
]

oc_path = os.path.join(work, "oc", "fixture.db")
oc_db(oc_path)
got, note = read_oc(oc_path)
check("opencode: 5 roots + 1 orphan record, in start order", len(got) == len(OC_EXPECTED), f"{len(got)} records")
for i, (g, e) in enumerate(zip(got, OC_EXPECTED)):
    g = plain(g)
    check(f"opencode record {i} ({e['proj']} {e['ts']}): exact dict", g == e,
          "\n".join(f"  {k}: got {g.get(k)!r}\n  {' ' * len(k)}  exp {e[k]!r}" for k in e if g.get(k) != e[k]))
check("opencode: no note on a readable db", note is None, note)
check("opencode: approval gap 2 on the synthetic root, '-' elsewhere",
      [ad.approval_gap(r["seq"]) for r in got] == [None] * 4 + [2, None], [ad.approval_gap(r["seq"]) for r in got])

OC_ROWS = [
    "2026-10-15 oc opencode-scratch-repo              big-pickle           3      1,923        249  11%     0      0     0      0.00     0.00     -  mimo-v2.6-flash-free:2 |  | reviewer@opencode/mimo-v2.6-flash-freex1 implementer@opencode/nemotron-3.5-lightning-freex1",
    "2026-10-16 oc opencode-t0-repo                   big-pickle           2      1,160        131  10%     2      0     1      0.00     0.00     -  big-pickle:3 cat-jam-free:2 | fp-probe:base | otherx3",
    "2026-10-16 oc opencode-t5-r1                     big-pickle           3      7,750      5,391  41%    11      0     5      0.00     0.00     -  cat-jam-free:10 deepseek-v4.1-flash-free:10 | fp:implementation-plan,fp:subagent-execution,fp:integration-review,fp:verify-done | implementer@seatx2 reviewer@seatx3",
    "2026-10-16 oc opencode-t5-r2                     big-pickle           2     10,215      7,016  41%     7      0     7      0.00     0.00     -  deepseek-v4.1-flash-free:12 cat-jam-free:11 | fp:implementation-plan,fp:subagent-execution,fp:integration-review,fp:verify-done,fp:finishing-a-development-branch | implementer@seatx2 reviewer@seatx2",
    "2026-10-18 oc oc-synth                           big-pickle           4        325        340  51%     2      1     3      2.50     2.75     2  big-pickle:2 deepseek-v4.1-flash-free:1 | fp:design-spec | implementer@seatx1 reviewerx1 reviewer@opencode/cat-jam-freex1",
    "2026-10-18 oc (orphan) oc-synth                  ?                    0          0         60 100%     0      0     0      0.00     1.00     -  cat-jam-free:1       |  | ",
]
# main 1923+1160+7750+10215+325 = 21,373; sub 249+131+5391+7016+340+60 = 13,187 (38.2%); edits 2+11+7+2 = 22,
# shell 1, sub 1+5+7+3 = 16; spend 2.50 + 2.75 + 1.00 = 6.25; spawns in first-seen order.
OC_SUM = ("sessions 6  out main 21,373 sub 13,187 (38.2% sub)  edits main 22 shell 1 sub 16  spend $6.25  "
          "spawns {'opencode/mimo-v2.6-flash-free': 1, 'opencode/nemotron-3.5-lightning-free': 1, '(unset)': 4, "
          "'seat': 10, 'opencode/cat-jam-free': 1}")
r = run(new, "--harness", "opencode", "--opencode-db", oc_path)
lines = r.stdout.decode().split("\n")
check("opencode printed: header and exact rows", r.returncode == 0 and r.stderr == b"" and lines[0] == HEADER_MULTI
      and lines[1:7] == OC_ROWS, "\n".join(f"got {a!r}\nexp {b!r}" for a, b in zip(lines[1:7], OC_ROWS) if a != b) + r.stderr.decode())
check("opencode printed: summary and all line", lines[7:10] == ["", "oc " + OC_SUM, "all " + OC_SUM], "\n".join(lines[7:10]))

# --since compares each session's UTC start date; children go with their root, never become orphans.
got16, _ = read_oc(oc_path, "2026-10-16")
check("opencode --since 2026-10-16: ec1f and its two children dropped", [plain(g) for g in got16] == OC_EXPECTED[1:],
      [(g["ts"], g["proj"]) for g in got16])
got17, _ = read_oc(oc_path, "2026-10-17")
check("opencode --since 2026-10-17: synthetic root and the orphan", [plain(g) for g in got17] == OC_EXPECTED[4:],
      [(g["ts"], g["proj"]) for g in got17])
got19, _ = read_oc(oc_path, "2026-10-19")
check("opencode --since 2026-10-19: nothing, the orphan included", got19 == [], [(g["ts"], g["proj"]) for g in got19])

# Without the (session_id, seq) index SQLite returns rows in insertion order, and the synthetic
# root's messages were inserted out of seq order: only ORDER BY seq keeps the record (and its gap).
noidx = os.path.join(work, "oc-noidx", "opencode.db")
os.makedirs(os.path.dirname(noidx))
c_ = sqlite3.connect(noidx)
c_.executescript(re.sub(r"CREATE (UNIQUE )?INDEX[^;]*;", "", OC_SQL)); c_.close()
got_ni, _ = read_oc(noidx)
check("opencode: messages read in seq order, not storage order", [plain(g) for g in got_ni] == OC_EXPECTED,
      [g["seq"] for g in got_ni[4:5]])

# Read-only, WAL-safe open: every row of this db lives in the -wal of a connection that is still open
# (OpenCode running). `immutable=1` would skip the WAL and see no tables at all.
wal_path = os.path.join(work, "oc-wal", "opencode.db")
writer = oc_db(wal_path, wal=True)
got_wal, note_wal = read_oc(wal_path)
check("opencode: rows still in the WAL of a live writer are read", [plain(g) for g in got_wal] == OC_EXPECTED and note_wal is None,
      (len(got_wal), note_wal))
writer.close()

# The URI path is quoted: `#`, `?` and `%` in a directory name.
odd = os.path.join(work, "a#b?c%d", "opencode.db")
oc_db(odd)
got_odd, note_odd = read_oc(odd)
check("opencode: db path with # ? % is opened", len(got_odd) == 6 and note_odd is None, (len(got_odd), note_odd))

real_connect, calls = sqlite3.connect, []


def spy(fail_ro=False):
    def connect(*args, **kw):
        calls.append((args, kw))
        if fail_ro and args[0].endswith("?mode=ro"):
            raise sqlite3.OperationalError("unable to open database file")
        return real_connect(*args, **kw)
    return connect


try:
    ad.sqlite3.connect = spy()
    read_oc(oc_path)
    check("opencode: opened once, as a `mode=ro` URI without immutable",
          len(calls) == 1 and calls[0][1].get("uri") is True and calls[0][0][0].endswith("?mode=ro")
          and "immutable" not in calls[0][0][0], calls)
    calls.clear()
    ad.sqlite3.connect = spy(fail_ro=True)
    got_imm, note_imm = read_oc(oc_path)
    check("opencode: a failed read-only open falls back to immutable=1, with a note",
          [plain(g) for g in got_imm] == OC_EXPECTED and calls[-1][0][0].endswith("?mode=ro&immutable=1")
          and note_imm == f"opened {oc_path} immutable (read-only open failed), so rows still in its WAL are missing",
          (calls, note_imm))
finally:
    ad.sqlite3.connect = real_connect

noc = os.path.join(work, "no-oc.db")
check("opencode: missing db -> no records and a note", read_oc(noc) == ([], f"no opencode logs at {noc}"), read_oc(noc))
old_db = os.path.join(work, "oc-1x.db")
c_ = sqlite3.connect(old_db); c_.execute("CREATE TABLE session (id text)"); c_.close()
check("opencode: a db without session_v2 -> no records and a note",
      read_oc(old_db) == ([], f"no session_v2 table in {old_db} (not an OpenCode 2.x db)"), read_oc(old_db))
junk = os.path.join(work, "junk.db")
with open(junk, "w") as fh:
    fh.write("not a database " * 100)
got_j, note_j = read_oc(junk)
check("opencode: a file that is not a db -> a note, no crash",
      got_j == [] and note_j.startswith(f"cannot read {junk} ("), note_j)

# A root session with no messages is dropped (as the Claude reader drops a transcript with no
# timestamp); a child with no messages is still a sub.
nomsg = os.path.join(work, "oc-nomsg", "opencode.db")
oc_db(nomsg)
c_ = sqlite3.connect(nomsg)
cols = "(id, project_id, parent_id, slug, directory, title, version, time_created, time_updated)"
c_.execute(f"INSERT INTO session_v2 {cols} VALUES ('ses_empty_root', 'p', NULL, 's', '/fixture/oc-empty', 't', '2', 1792285200000, 1792285200000)")
c_.execute(f"INSERT INTO session_v2 {cols} VALUES ('ses_empty_kid', 'p', 'ses_fixture000000ocRootGap0001', 's', '/fixture/oc-synth', 't', '2', 1792285390000, 1792285390000)")
# a root with no messages whose child has some is kept, so the child's work is not lost
c_.execute(f"INSERT INTO session_v2 {cols} VALUES ('ses_empty_root2', 'p', NULL, 's', '/fixture/oc-empty2', 't', '2', 1792371600000, 1792371600000)")
c_.execute(f"INSERT INTO session_v2 {cols} VALUES ('ses_busy_kid', 'p', 'ses_empty_root2', 's', '/fixture/oc-empty2', 't', '2', 1792371660000, 1792371660000)")
c_.execute("INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES "
           "('msg_busy', 'ses_busy_kid', 'assistant', 1, 1792371670000, 1792371670000, "
           "'{\"model\": {\"id\": \"m-x\"}, \"tokens\": {\"output\": 7}, \"cost\": 0.5}')")
c_.commit(); c_.close()
got_nm, _ = read_oc(nomsg)
exp_nm = [dict(e) for e in OC_EXPECTED]
exp_nm[4] = dict(exp_nm[4], subs=exp_nm[4]["subs"] + [osub({}, 0, 0.0, 0)])
exp_nm.insert(5, oc("2026-10-19", "oc-empty2", {}, 0, 0, 0.0, [], [], 0, 0, [], [osub({"m-x": 1}, 7, 0.5, 0)]))
check("opencode: a root with no messages is dropped unless it has descendants; a child with none is still a sub",
      [plain(g) for g in got_nm] == exp_nm, [(g["ts"], g["proj"], len(g["subs"])) for g in got_nm])

# An SQLite error after the open succeeds (schema drift here: session_message without `seq`; on a live
# db, `database is locked`) is a note, never a crash.
drift = os.path.join(work, "oc-drift", "opencode.db")
os.makedirs(os.path.dirname(drift))
c_ = sqlite3.connect(drift)
c_.execute("CREATE TABLE session_v2 (id text, parent_id text, directory text, time_created integer)")
c_.execute("CREATE TABLE session_message (session_id text, type text, data text)")
c_.execute("INSERT INTO session_v2 VALUES ('s1', NULL, '/fixture/x', 1792285200000)")
c_.commit(); c_.close()
got_dr, note_dr = read_oc(drift)
check("opencode: an SQLite error after the open -> no records and a note",
      got_dr == [] and note_dr == f"cannot read {drift} (no such column: seq)", (got_dr, note_dr))
r = run(new, "--harness", "opencode", "--opencode-db", drift)
check("opencode: an SQLite error after the open does not crash the run",
      r.returncode == 0 and r.stderr == b"" and f"oc note: cannot read {drift} (no such column: seq)" in r.stdout.decode(),
      r.stdout.decode() + r.stderr.decode())

# --- Pi reader ------------------------------------------------------------------------------
# Expected values: tests/analysis/fixtures/README.md (Pi table), hand-derived, with the rulings
# applied (usr = user messages only; an approval result is an `approved` gap event; the separate
# extension's `subagent` calls are spawns; every skill listed). Costs: the per-message
# usage.cost.total values, listed here and compared at 10 decimals.
import math
pi_fx = os.path.join(repo, "tests", "analysis", "fixtures", "pi")
DSF, QW, GE = "deepseek/deepseek-v4-flash", "qwen/qwen3.6-flash", "google/gemini-3.1-flash-lite"


def psub(models, out, costs, edits):
    return dict(models=models, out=out, cost=round(math.fsum(costs), 10), edits=edits)


def pi(ts, proj, models, usr, out, costs, skills, spawns, edits, bw, seq, subs):
    return dict(harness="pi", ts=ts, proj=proj, models=models, user_turns=usr, out=out, cost=round(math.fsum(costs), 10),
                skills=skills, spawns=[dict(role=r, model=m) for r, m in spawns], edits=edits, bash_writes=bw, seq=seq,
                subs=subs)


def pplain(r):
    r = plain(r)
    return dict(r, cost=round(r["cost"], 10), subs=[dict(x, cost=round(x["cost"], 10)) for x in r["subs"]])


FX = "/fixture/"
PI_FLAT = [
    # e336 (pi2): a `/skill:` message is a user turn and a skill load.
    pi("2026-10-17", "pi2-work", {DSF: 1}, 1, 8, [4.96026e-05], ["fablepowers:nsdemo"], [], 0, 0,
       [("user", '<skill name="fablepowers:nsdemo" location="/fixture/plugins/'), ("skill", "nsdemo")], []),
    # da07 (pi-t0 r4): 76+116+63+62+70+72+3 = 462. Two seat dispatches, then three `subagent` calls of the
    # separate extension (all errored; attempts): agent x + "review placeholder" -> reviewer, `tasks`/`chain`
    # (no agent, no task) -> other; none passes a model.
    pi("2026-10-17", "pi-t0-work", {DSF: 7}, 1, 462,
       [0.000208152, 0.000173439, 0.0001105632, 0.0001168812, 0.0001212624, 0.0001276164, 0.0000437436], [],
       [("reviewer", "seat"), ("implementer", "seat"), ("reviewer", None), ("other", None), ("other", None)], 1, 0,
       [("user", REV), ("edit", FX + "pi-t0-work/f1.txt")], []),
    # 850c (pi-t5 main): 155+96+95+70+264+121+124 = 925; the first dispatch errored (still an attempt).
    # Approved result, no design-spec -> gap '-'. Children 9b68 and b8fa via fablepowers-child entries.
    pi("2026-10-17", "pi-t5-r1", {DSF: 7}, 3, 925,
       [0.00042705, 0.0001873764, 0.0001858896, 0.0001590948, 0.0003940578, 0.0002321172, 0.0002440134], [],
       [("implementer", "seat"), ("reviewer", "seat"), ("implementer", "seat")], 1, 0,
       [("user", PH), ("edit", FX + "pi-t5-r1/docs/specs/f1.md"), ("user", REV), ("approved", "k1"), ("user", IMP)],
       [psub({GE: 1}, 2, [0.001295], 0),
        psub({QW: 9}, 205 + 213 + 542 + 445 + 465 + 187 + 242 + 177 + 276,
             [0.0011821875, 0.001231875, 0.001651125, 0.001656375, 0.001729125, 0.0014615625, 0.0015500625, 0.001540125,
              0.00167775], 2)]),
    # d69c (pi-t5 r2): 74+41+55+79+232+131 = 612; two not-recorded results (no event), one approved.
    pi("2026-10-17", "pi-t5-r2", {DSF: 6}, 3, 612,
       [0.000332928, 0.0001278162, 0.0001424844, 0.0001677726, 0.0003568086, 0.000238167], [], [], 1, 0,
       [("user", PH), ("edit", FX + "pi-t5-r2/docs/specs/f1.md"), ("user", PH), ("ask", ""), ("user", PH),
        ("approved", "k1")], []),
    # 1892 (pi-t5 main): 131+74+55+35 = 295; a withdraw result (no event).
    pi("2026-10-17", "pi-t5-r1", {DSF: 4}, 2, 295, [0.000399492, 0.0001777572, 0.0001464246, 0.0001210248], [], [], 2, 0,
       [("user", PH), ("edit", FX + "pi-t5-r1/docs/specs/f1.md"), ("edit", FX + "pi-t5-r1/docs/specs/f2.md"),
        ("user", PH), ("ask", "")], []),
    # ad38 (killed parent, no entry): child b9ba linked by its directory only.
    pi("2026-10-17", "pi-t5-r4", {DSF: 1}, 1, 129, [0.000398493], [], [("implementer", "seat")], 0, 0, [("user", IMP)],
       [psub({QW: 1}, 121, [0.001089375], 0)]),
]
PI_DEFAULT = [
    # synthetic root: out 100+50+80+20, cost 1.1+0.4+0.75+0; the wrapper read and the SKILL.md read are one
    # load; withdraw / not-recorded results add nothing, the approved one is an event; gap 3.
    pi("2026-10-18", "pi-synth", {DSF: 4}, 3, 250, [1.1, 0.4, 0.75, 0.0], ["fablepowers:design-spec", "fablepowers:verify-done"],
       [("implementer", "seat"), ("reviewer", "seat")], 2, 1,
       [("user", PH), ("skill", "design-spec"), ("user", PH), ("ask", ""), ("edit", FX + "pi-synth/docs/specs/f1.md"),
        ("approved", "k1"), ("user", '<skill name="fablepowers-verify-done" location="/fixture/plu'),
        ("skill", "verify-done"), ("edit", "bash-write"), ("edit", FX + "pi-synth/src/f2.py")],
       # …02 via the entry (write + edit; the sed -i is not a sub edit), …03 via the directory only.
       [psub({QW: 1}, 300, [2.2], 2), psub({GE: 1}, 40, [1.05], 0)]),
    # orphan: …04 sits under fablepowers-children/…ff/, whose session does not exist.
    pi("2026-10-18", "(orphan) pi-synth", {}, 0, 0, [0.0], [], [], 0, 0, [], [psub({QW: 1}, 60, [1.0], 0)]),
]


def read_p(d, since=None):
    return ad.read_pi(argparse.Namespace(pi_sessions=d, since=since))


def same(name, got, exp):
    check(f"{name}: {len(exp)} records", len(got) == len(exp), [(g["ts"], g["proj"]) for g in got])
    for i, (g, e) in enumerate(zip(got, exp)):
        g = pplain(g)
        check(f"{name} record {i} ({e['proj']} {e['ts']}): exact dict", g == e,
              "\n".join(f"  {k}: got {g.get(k)!r}\n  {' ' * len(k)}  exp {e[k]!r}" for k in e if g.get(k) != e[k]))


flat, default = os.path.join(pi_fx, "flat"), os.path.join(pi_fx, "default")
got, note = read_p(flat)
same("pi flat (--session-dir layout)", got, PI_FLAT)
check("pi flat: no note", note is None, note)
got_d, note_d = read_p(default)
same("pi default (--<cwd>-- layout)", got_d, PI_DEFAULT)
check("pi default: no note; notes.txt ignored", note_d is None, note_d)
check("pi: approval gap 3 on the synthetic root, '-' elsewhere",
      [ad.approval_gap(r["seq"]) for r in got + got_d] == [None] * 6 + [3, None], [ad.approval_gap(r["seq"]) for r in got + got_d])

# Both layouts under one sessions dir (a flat dir and a --<cwd>-- dir side by side). Roots in path
# order (`--fixture-pi-synth--/` sorts before the flat files), then the orphan.
both = os.path.join(work, "pi-both")
shutil.copytree(flat, both); shutil.copytree(os.path.join(default, "--fixture-pi-synth--"), os.path.join(both, "--fixture-pi-synth--"))
got_b, _ = read_p(both)
same("pi both layouts", got_b, PI_DEFAULT[:1] + PI_FLAT + PI_DEFAULT[1:])

PI_ROWS_FLAT = [
    "2026-10-17 pi pi2-work                           deepseek-v4-flash    1          8          0   0%     0      0     0      0.00     0.00     -                       | fp:nsdemo | ",
    "2026-10-17 pi pi-t0-work                         deepseek-v4-flash    1        462          0   0%     1      0     0      0.00     0.00     -                       |  | reviewer@seatx1 implementer@seatx1 reviewerx1 otherx2",
    "2026-10-17 pi pi-t5-r1                           deepseek-v4-flash    3        925      2,754  75%     1      0     2      0.00     0.01     -  qwen3.6-flash:9 gemini-3.1-flash-lite:1 |  | implementer@seatx2 reviewer@seatx1",
    "2026-10-17 pi pi-t5-r2                           deepseek-v4-flash    3        612          0   0%     1      0     0      0.00     0.00     -                       |  | ",
    "2026-10-17 pi pi-t5-r1                           deepseek-v4-flash    2        295          0   0%     2      0     0      0.00     0.00     -                       |  | ",
    "2026-10-17 pi pi-t5-r4                           deepseek-v4-flash    1        129        121  48%     0      0     0      0.00     0.00     -  qwen3.6-flash:1      |  | implementer@seatx1",
]
PI_ROWS_DEFAULT = [
    "2026-10-18 pi pi-synth                           deepseek-v4-flash    3        250        340  58%     2      1     2      2.25     3.25     3  qwen3.6-flash:1 gemini-3.1-flash-lite:1 | fp:design-spec,fp:verify-done | implementer@seatx1 reviewer@seatx1",
    "2026-10-18 pi (orphan) pi-synth                  ?                    0          0         60 100%     0      0     0      0.00     1.00     -  qwen3.6-flash:1      |  | ",
]
# flat: main 8+462+925+612+295+129 = 2,431; sub 2,754+121 = 2,875 (54.2%); edits 1+1+1+2 = 5; sub 2;
# spend ≈ $0.02; spawns seat 2+3+1 = 6, (unset) 3. default: main 250, sub 340+60 = 400 (61.5%); spend
# 2.25 + 3.25 + 1.00 = 6.50.
PI_SUM_FLAT = "sessions 6  out main 2,431 sub 2,875 (54.2% sub)  edits main 5 shell 0 sub 2  spend $0.02  spawns {'seat': 6, '(unset)': 3}"
PI_SUM_DEFAULT = "sessions 2  out main 250 sub 400 (61.5% sub)  edits main 2 shell 1 sub 2  spend $6.50  spawns {'seat': 2}"
for label, d, rows_, sum_ in (("flat", flat, PI_ROWS_FLAT, PI_SUM_FLAT), ("default", default, PI_ROWS_DEFAULT, PI_SUM_DEFAULT)):
    r = run(new, "--harness", "pi", "--pi-sessions", d)
    lines = r.stdout.decode().split("\n")
    n = len(rows_)
    check(f"pi {label} printed: header and exact rows", r.returncode == 0 and r.stderr == b""
          and lines[0] == HEADER_MULTI and lines[1:n + 1] == rows_,
          "\n".join(f"got {a!r}\nexp {b!r}" for a, b in zip(lines[1:n + 1], rows_) if a != b) + r.stderr.decode())
    check(f"pi {label} printed: summary and all line", lines[n + 1:n + 4] == ["", "pi " + sum_, "all " + sum_],
          "\n".join(lines[n + 1:n + 4]))

# --since compares each session's UTC start date; children go with their root.
got17, _ = read_p(flat, "2026-10-17")
check("pi --since 2026-10-17 keeps every flat session", [pplain(g) for g in got17] == PI_FLAT, [(g["ts"], g["proj"]) for g in got17])
got18, _ = read_p(both, "2026-10-18")
check("pi --since 2026-10-18: the synthetic root and the orphan", [pplain(g) for g in got18] == PI_DEFAULT,
      [(g["ts"], g["proj"]) for g in got18])
check("pi --since 2026-10-19: nothing, the orphan included", read_p(both, "2026-10-19")[0] == [])

nopi = os.path.join(work, "no-pi")
check("pi: missing dir -> no records and a note", read_p(nopi) == ([], f"no pi logs at {nopi}"), read_p(nopi))

# --- Pi rules the fixtures do not exercise: sessions written here ----------------------------
def pi_session(path, sid, entries, ts="2026-10-20T10:00:00.000Z", cwd="/w/pi-rules"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(json.dumps({"type": "session", "version": 3, "id": sid, "timestamp": ts, "cwd": cwd}) + "\n")
        for e in entries:
            fh.write(json.dumps(e) + "\n")


def amsg(*calls, model="m-main", out=10, cost=1.0):
    return {"type": "message", "message": {"role": "assistant", "model": model, "content": [
        {"type": "toolCall", "name": n, "arguments": a} for n, a in calls],
        "usage": {"output": out, "cost": {"total": cost}}}}


def umsg(text):
    return {"type": "message", "message": {"role": "user", "content": text}}


def result(text, ctype="fablepowers-result"):
    return {"type": "custom_message", "customType": ctype, "content": [{"type": "text", "text": text}]}


prs = os.path.join(work, "pi-rules")
CH = "fablepowers-children"
pi_session(os.path.join(prs, "a.jsonl"), "R1", [
    umsg("start"),
    # a bash cat of the real SKILL.md right after the wrapper read is the same load; a later one is a new load.
    amsg(("read", {"path": "/p/fablepowers/pi/skills/fablepowers-design-spec/SKILL.md"}),
         ("bash", {"command": "cat /p/fablepowers/skills/design-spec/SKILL.md"}),
         ("write", {"path": "/p/x/skills/design-spec/SKILL.md"}),  # writing a SKILL.md is an edit, not a load
         ("bash", {"command": "rg x /p/skills/other/SKILL.md"}),  # rg is not a read
         ("read", {"path": "/p/other/skills/mine/SKILL.md"})),  # a non-fablepowers skill, listed bare
    # dispatches: a strict-implementer seat; a seat call passing a model; a dispatch without a seat (heuristic);
    # the extension's `tasks` list (role from the first item's agent, model from the args).
    amsg(("fablepowers_dispatch", {"seat": "strict-implementer", "task": "review it"}),
         ("fablepowers_dispatch", {"seat": "reviewer", "task": "x", "model": "m-req"}),
         ("fablepowers_dispatch", {"task": "please review this"}),
         ("subagent", {"tasks": [{"agent": "reviewer", "task": "implement x"}, {"agent": "worker", "task": "y"}],
                       "model": "m-sub"})),
    {"type": "custom", "customType": "fablepowers-child", "data": {"seat": "implementer", "childSessionId": "C-ELSE"}},
    {"type": "custom", "customType": "fablepowers-child", "data": {"seat": "reviewer", "childSessionId": "C-MOVED"}},
    # the gate's other approved wording (no key): the design path is the value.
    result("fablepowers approval gate: the user approved design `docs/specs/s.md`; the approval is recorded."),
    # the ask-approval tool's own result is a tool result, not an approval event; other custom types neither.
    {"type": "message", "message": {"role": "toolResult", "toolName": "fablepowers_ask_approval",
                                    "content": [{"type": "text", "text": "the user approved design `x` (key `t`)"}]}},
    result("fablepowers approval gate: the user approved design `y` (key `z`)", ctype="fp-approve"),
    amsg(("bash", {"command": "cat /p/fablepowers/skills/design-spec/SKILL.md"})),
])
# linked by R1's entry only, from a directory that says nothing about its parent
pi_session(os.path.join(prs, "elsewhere", "c.jsonl"), "C-ELSE", [amsg(model="m-c", out=7, cost=0.5)], ts="2026-10-20T10:01:00.000Z")
# R1's entry wins over the directory, which names R2
pi_session(os.path.join(prs, CH, "R2", "d.jsonl"), "C-MOVED", [amsg(model="m-d", out=3, cost=0.25)], ts="2026-10-20T10:02:00.000Z")
# depth 2: a child of C-ELSE placed under the child's own fablepowers-children dir
pi_session(os.path.join(prs, "elsewhere", CH, "C-ELSE", "g.jsonl"), "G1", [amsg(("edit", {"path": "f"}), model="m-g", out=2, cost=0.125)],
           ts="2026-10-20T10:03:00.000Z")
pi_session(os.path.join(prs, "b.jsonl"), "R2", [umsg("x")], ts="2026-10-21T10:00:00.000Z")
# not sessions: a .jsonl without a session header, an empty .jsonl, a header without a timestamp
with open(os.path.join(prs, "junk.jsonl"), "w") as fh:
    fh.write('{"type":"message","id":"J1","timestamp":"2026-10-20T10:00:00.000Z"}\n')
open(os.path.join(prs, "empty.jsonl"), "w").close()
with open(os.path.join(prs, "nots.jsonl"), "w") as fh:
    fh.write('{"type":"session","id":"N1"}\n')
got, note = read_p(prs)
g = pplain(got[0]) if got else {}
check("pi synthetic: two roots (R1, R2), non-session files and an undated header ignored",
      [(x["ts"], x["proj"]) for x in got] == [("2026-10-20", "pi-rules"), ("2026-10-21", "pi-rules")] and note is None,
      [(x["ts"], x["proj"]) for x in got])
check("pi synthetic: skills -- wrapper + bash cat is one load, a later cat a new one, non-fablepowers listed bare",
      g.get("skills") == ["fablepowers:design-spec", "mine", "fablepowers:design-spec"], g.get("skills"))
check("pi synthetic: a write to a SKILL.md is an edit", g.get("edits") == 1, g.get("edits"))
check("pi synthetic: spawns -- strict seat, requested model, no seat, extension `tasks` list",
      g.get("spawns") == [dict(role="implementer", model="seat"), dict(role="reviewer", model="m-req"),
                          dict(role="reviewer", model="seat"), dict(role="reviewer", model="m-sub")], g.get("spawns"))
check("pi synthetic: approval without a key -> the design path; tool results and other custom types are not events",
      [x for x in g.get("seq", []) if x[0] == "approved"] == [("approved", "docs/specs/s.md")], g.get("seq"))
check("pi synthetic: subs in path order -- entry-linked child elsewhere, depth-2 grandchild rolled up, entry beats directory",
      g.get("subs") == [psub({"m-c": 1}, 7, [0.5], 0), psub({"m-g": 1}, 2, [0.125], 1), psub({"m-d": 1}, 3, [0.25], 0)],
      g.get("subs"))
check("pi synthetic: R2 has no subs (its directory child belongs to R1)", got[1]["subs"] == [] if len(got) > 1 else False)

# Pi forks and clones (`/fork`, `/clone`: SessionManager.createBranchedSession / forkFrom) write a new
# session file with a new header id, `parentSession` = the source file's path, and copies of the source's
# entries with their entry ids. Copied entries belong to the source; the fork's row counts only its own.
forks = os.path.join(work, "pi-forks")
shutil.copytree(flat, forks)
D69C = os.path.join(forks, "2026-10-17T09-03-12-541Z_01a14919-d69c-767d-a208-b1af3b3ae282.jsonl")
P850C = os.path.join(forks, "2026-10-17T09-02-51-661Z_01a14919-850c-77d5-8e65-641713cdb743.jsonl")


def fork(src, name, sid, new_entries, ts="2026-10-19T10:00:00.000Z", parent=None):
    with open(src) as fh:
        lines = fh.read().splitlines()
    with open(os.path.join(forks, name), "w") as fh:
        fh.write(json.dumps({"type": "session", "version": 3, "id": sid, "timestamp": ts, "cwd": "/fixture/pi-fork",
                             "parentSession": parent or src}) + "\n")
        for l in lines[1:]:
            fh.write(l + "\n")
        for e in new_entries:
            fh.write(json.dumps(e) + "\n")


fork(D69C, "2026-10-19T10-00-00-000Z_fork-1.jsonl", "FORK-1",
     [dict(umsg("go on"), id="new00001"), dict(amsg(("edit", {"path": "/fixture/pi-fork/f9.py"}), out=5, cost=0.5), id="new00002")])
# a clone of the fork (fork of a fork): its parent file is the fork; the parent path is given relative
# to another directory, so the reader matches it by file name.
fork(os.path.join(forks, "2026-10-19T10-00-00-000Z_fork-1.jsonl"), "2026-10-19T11-00-00-000Z_fork-2.jsonl", "FORK-2",
     [dict(amsg(out=3, cost=0.25), id="new00003")], ts="2026-10-19T11:00:00.000Z",
     parent="/elsewhere/2026-10-19T10-00-00-000Z_fork-1.jsonl")
# an unused clone of 850c copies its fablepowers-child entries: the children stay with 850c, and the
# clone, with no entries of its own and no descendants, has no row.
fork(P850C, "2026-10-19T12-00-00-000Z_clone-3.jsonl", "CLONE-3", [], ts="2026-10-19T12:00:00.000Z")
# dedup is store-wide by entry id: an unrelated session (no parentSession) that holds an id an earlier
# session holds (dc1b57e8, from d69c) does not count that entry. Pi ids are 8 random hex digits checked
# unique per file, so a true collision between unrelated sessions is negligible; this one is planted.
pi_session(os.path.join(forks, "2026-10-19T13-00-00-000Z_unrelated.jsonl"), "UNREL",
           [dict(amsg(out=4, cost=0.125), id="dc1b57e8"), dict(amsg(out=6, cost=0.25), id="unrel001")],
           ts="2026-10-19T13:00:00.000Z", cwd="/fixture/pi-fork")
got_f, note_f = read_p(forks)
PI_FORKS = PI_FLAT + [
    pi("2026-10-19", "pi-fork", {"m-main": 1}, 1, 5, [0.5], [], [], 1, 0,
       [("user", "go on"), ("edit", "/fixture/pi-fork/f9.py")], []),
    pi("2026-10-19", "pi-fork", {"m-main": 1}, 0, 3, [0.25], [], [], 0, 0, [], []),
    pi("2026-10-19", "pi-fork", {"m-main": 1}, 0, 6, [0.25], [], [], 0, 0, [], []),
]
same("pi forks: originals unchanged, each fork counts only its own entries", got_f, PI_FORKS)
check("pi forks: no note", note_f is None, note_f)


# Store-wide dedup: an entry id is counted once, in the earliest session (header timestamp, then file
# name) that holds it, whichever `parentSession` files exist. S -> F1 -> F2: S has 600 out (100 with an
# edit, 200, 300) and $0.6, F1 adds 7, F2 adds 11. Before this rule a deleted F1 made F2 618. File names sort against the timestamps (F2's first),
# so the owner comes from the header timestamp, not the file name.
def chain(d, keep):
    S = [dict(umsg("start"), id="s0000001"), dict(amsg(("edit", {"path": "f"}), out=100, cost=0.1), id="s0000002"),
         dict(amsg(out=200, cost=0.2), id="s0000003"), dict(amsg(out=300, cost=0.3), id="s0000004")]
    F1 = S + [dict(amsg(out=7, cost=0.007), id="f1000001")]
    F2 = F1 + [dict(amsg(out=11, cost=0.011), id="f2000001")]
    for name, sid, entries, ts in (("c-s.jsonl", "S", S, "2026-10-22T09:00:00.000Z"),
                                   ("b-f1.jsonl", "F1", F1, "2026-10-22T10:00:00.000Z"),
                                   ("a-f2.jsonl", "F2", F2, "2026-10-22T11:00:00.000Z")):
        if sid in keep:
            pi_session(os.path.join(d, name), sid, entries, ts=ts, cwd="/w/pi-chain")
            if sid != "S":  # parentSession names the direct source, which may be gone
                with open(os.path.join(d, name)) as fh:
                    lines = fh.read().splitlines()
                h = json.loads(lines[0]); h["parentSession"] = os.path.join(d, "c-s.jsonl" if sid == "F1" else "b-f1.jsonl")
                with open(os.path.join(d, name), "w") as fh:
                    fh.write("\n".join([json.dumps(h)] + lines[1:]) + "\n")
    return read_p(d)[0]


def outs(rows):
    return [(r["out"], round(r["cost"], 10), r["edits"], r["user_turns"]) for r in sorted(rows, key=lambda r: r["out"])]


for label, keep, want in (("all present", ("S", "F1", "F2"), [(7, 0.007, 0, 0), (11, 0.011, 0, 0), (600, 0.6, 1, 1)]),
                          # F1's own +7 now exists only in F2's copy: counted once, there; S's 600 is not repeated.
                          ("middle link F1 deleted", ("S", "F2"), [(18, 0.018, 0, 0), (600, 0.6, 1, 1)]),
                          ("source S deleted", ("F1", "F2"), [(11, 0.011, 0, 0), (607, 0.607, 1, 1)])):
    got_c = chain(os.path.join(work, "pi-chain-" + "".join(keep)), keep)
    check(f"pi fork chain, {label}: each entry counted once, in its earliest session", outs(got_c) == want, outs(got_c))

# Same header timestamp: the file name breaks the tie. Both hold entry `same0001` (5 out).
tie = os.path.join(work, "pi-tie")
pi_session(os.path.join(tie, "b.jsonl"), "TB", [dict(amsg(out=5, cost=0.5), id="same0001"), dict(amsg(out=2, cost=0.25), id="tb000001")],
           ts="2026-10-22T09:00:00.000Z")
pi_session(os.path.join(tie, "a.jsonl"), "TA", [dict(amsg(out=5, cost=0.5), id="same0001"), dict(amsg(out=1, cost=0.125), id="ta000001")],
           ts="2026-10-22T09:00:00.000Z")
got_t = read_p(tie)[0]
check("pi dedup tie on timestamp: the earlier file name owns the shared entry",
      [(r["out"], r["cost"]) for r in got_t] == [(6, 0.625), (2, 0.25)], [(r["out"], r["cost"]) for r in got_t])
# A header without a timestamp has no row; it holds a copy of TA's shared entry and sorts first by
# name, but undated sessions own nothing ahead of dated ones, so the rows above do not change.
with open(os.path.join(tie, "0.jsonl"), "w") as fh:
    fh.write(json.dumps({"type": "session", "id": "UNDATED"}) + "\n"
             + json.dumps(dict(amsg(out=5, cost=0.5), id="same0001")) + "\n")
got_t = read_p(tie)[0]
check("pi dedup: an undated session owns no entry ahead of dated ones",
      [(r["out"], r["cost"]) for r in got_t] == [(6, 0.625), (2, 0.25)], [(r["out"], r["cost"]) for r in got_t])

# A root with no counted entries is left out unless it has descendants (OpenCode's rule): an empty
# session is dropped, an empty parent of a child with work is kept (the clone case is CLONE-3 above).
emp = os.path.join(work, "pi-empty")
pi_session(os.path.join(emp, "a.jsonl"), "EMPTY", [], ts="2026-10-22T09:00:00.000Z", cwd="/w/pi-empty")
pi_session(os.path.join(emp, "b.jsonl"), "EMPTY-P", [], ts="2026-10-22T09:01:00.000Z", cwd="/w/pi-empty")
pi_session(os.path.join(emp, CH, "EMPTY-P", "c.jsonl"), "KID", [amsg(model="m-k", out=5, cost=0.5)], ts="2026-10-22T09:02:00.000Z", cwd="/w/pi-empty")
pi_session(os.path.join(emp, "d.jsonl"), "ONLY-USER", [umsg("hi")], ts="2026-10-22T09:03:00.000Z", cwd="/w/pi-empty")
got_e = read_p(emp)[0]
same("pi empty roots: dropped unless they have descendants; a user message counts", got_e, [
    pi("2026-10-22", "pi-empty", {}, 0, 0, [], [], [], 0, 0, [], [psub({"m-k": 1}, 5, [0.5], 0)]),
    pi("2026-10-22", "pi-empty", {}, 1, 0, [0.0], [], [], 0, 0, [("user", "hi")], [])])

# approval_gap: an `approved` event counts as a user turn; nothing else new counts.
check("approval_gap counts `approved` events like user turns",
      ad.approval_gap([("skill", "design-spec"), ("approved", "k"), ("ask", ""), ("user", "u"), ("edit", "src/x.py"), ("approved", "k")]) == 2)

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
