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
#     the rules the real fixtures do not exercise.
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
    # 67db (v2): agent_type fp-implementer -> implementer, no model passed; depth-2 grandchild 85ec rolled up.
    cx("2026-10-15", "codex-repo", {S6: 1}, 1, 264, [], [("implementer", None)], 0, 0, [("user", IMP)],
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
    "2026-10-15 cx codex-repo                         gpt-6-luna   1       264      363  58%     0      0     0      -     -     -  gpt-5.6-terra:2      |  | implementerx1",
    "2026-10-15 cx codex-repo                         gpt-6-luna   1       157        0   0%     1      0     0      -     -     -                       |  | ",
    "2026-10-15 cx codex2-repo                        gpt-5.6-luna   1       960      223  19%     1      0     1      -     -     -  gpt-5.6-luna:2       | fp:workflow,fp:subagent-execution | implementer@gpt-5.6-lunax1 other@gpt-5.6-lunax1",
    "2026-10-15 cx codex-port-t0-repo                 gpt-5.6-luna   1       339        6   2%     1      0     0      -     -     -  gpt-5.6-luna:1       |  | reviewer@gpt-5.6-lunax1",
    "2026-10-15 cx codex-port-t0-repo                 gpt-6-luna   3       103        0   0%     0      0     0      -     -     -                       | fp:approve | ",
    "2026-10-17 cx codex-r1                           gpt-6-luna   4     4,026    2,126  35%     3      0     1      -     -     -  gpt-6-luna:4         | fp:approve,fp:implementation-plan,fp:subagent-execution,fp:behavioral-testing,fp:integration-review | implementer@gpt-6-lunax3 reviewer@gpt-6-lunax2",
    "2026-10-18 cx cx-synth                           gpt-6-sol    5       600      450  43%     2      1     1      -     -     3  gpt-6-luna:1         | fp:design-spec | reviewer@gpt-6-lunax1",
    "2026-10-18 cx (orphan) cx-synth                  ?            0         0       70 100%     0      0     0      -     -     -  gpt-6-luna:1         |  | ",
]
# main 264+157+960+339+103+4026+600 = 6,449; sub 363+223+6+2126+450+70 = 3,238 (33.4%);
# edits 1+1+1+3+2 = 8, shell 1, sub 1+1+1 = 3; spawns (unset) 1, gpt-5.6-luna 3, gpt-6-luna 6.
CX_SUM = ("sessions 8  out main 6,449 sub 3,238 (33.4% sub)  edits main 8 shell 1 sub 3  spend n/a  "
          "spawns {'(unset)': 1, 'gpt-5.6-luna': 3, 'gpt-6-luna': 6}")
r = run(new, "--harness", "codex", "--codex-home", codex_home)
lines = r.stdout.decode().split("\n")
check("codex printed: header and exact rows", r.returncode == 0 and r.stderr == b"" and lines[0] == f"date       h  {HEADER_TAIL}"
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
got, note = read_cx(synth)
g = plain(got[0]) if got else {}
check("codex synthetic: one root", len(got) == 1, [x["proj"] for x in got])
check("codex synthetic: spawns -- JS attempt without a CollabAgentToolCall (literal model + seat), child seat line, child agent_role, agent_type",
      g.get("spawns") == [dict(role="implementer", model="m-a"), dict(role="implementer", model="m-b"),
                          dict(role="reviewer", model=None), dict(role="implementer", model="m-d")], g.get("spawns"))
check("codex synthetic: a top-level apply_patch attempt is an edit of the patched file; a FileChange counts its files",
      g.get("edits") == 3 and [x for x in g.get("seq", []) if x[0] == "edit"]
      == [("edit", "docs/plans/p.md"), ("edit", "docs/specs/s.md"), ("edit", "src/x.py")], g)
check("codex synthetic: only read verbs load a skill; non-fablepowers skills listed bare", g.get("skills") == ["mine"], g.get("skills"))
check("codex synthetic: out falls back to the last token_count total", g.get("out") == 9, g.get("out"))
check("codex synthetic: worktree cwd -> repo/worktree", g.get("proj") == "repo/wt", g.get("proj"))
check("codex synthetic: subs are k1 and k2", [s["models"] for s in g.get("subs", [])] == [{"m-a": 1}, {"m-c": 1}], g.get("subs"))
check("codex synthetic: a non-spawn subagent rollout is skipped with a note",
      note == "1 non-spawn subagent rollout(s) skipped", note)

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
