#!/usr/bin/env python3
"""Per-session delegation analysis for Claude Code session logs.

Answers one question: when you ran this workflow, who actually did the work --
the orchestrator in the main loop, or the subagents it dispatched?

Claude Code writes one JSONL transcript per session under `~/.claude/projects`
(read by default; override with --projects-dir), plus one
`<session>/subagents/agent-*.jsonl` per dispatched subagent. Naive log counters
treat those subagent files as sessions of their own. This script pairs each main
transcript with its subagent transcripts and reports, per session:

  * main-loop vs subagent output tokens (who is doing the work)
  * who edits files: main-loop Edit/Write + Bash heredoc writes vs subagent edits
  * which model each subagent actually ran on (from the assistant records)
  * the `model` param passed on Agent spawns (unset => inherits the main model)
  * skills invoked, and whether design-spec's approval checkpoint got a user turn
  * a rough $ estimate per session (see PRICE below)

Usage:
    python3 scripts/analyze_delegation.py [--since YYYY-MM-DD] [--projects-dir DIR]

Stdlib only.
"""
import argparse, collections, glob, json, os, re

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
# $/MTok: input, cache_write, cache_read, output.
# Snapshot of public list prices as of June 2026 -- update it before trusting the
# dollar columns. The fable-5 cache-read rate is an assumption, not a published
# number; every other row comes from the published table.
PRICE = {
    "claude-fable-5-1": (10, 12.5, 0.25, 50), "claude-fable-5": (10, 12.5, 1.0, 50),
    "claude-opus-5": (5, 6.25, 0.5, 25), "claude-opus-4-8": (5, 6.25, 0.5, 25),
    "claude-sonnet-5": (2, 2.5, 0.2, 10), "claude-haiku-4-5-20251001": (1, 1.25, 0.1, 5),
}
WRITE_RE = re.compile(r"cat\s*>|<<\s*'?EOF|sed\s+-i|tee\s|>\s*\S+\.(py|ts|tsx|js|dart|md|json|ya?ml|toml|sh|css|html)")


def recs(path):
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def cost(usage, model):
    p = PRICE.get(model)
    if not p:
        return 0.0
    return (usage.get("input_tokens", 0) * p[0] + usage.get("cache_creation_input_tokens", 0) * p[1]
            + usage.get("cache_read_input_tokens", 0) * p[2] + usage.get("output_tokens", 0) * p[3]) / 1e6


AGENT_ROLES = {"fablepowers:reviewer": "reviewer",
               "fablepowers:implementer": "implementer",
               "fablepowers:strict-implementer": "implementer"}


def role(prompt, desc="", subagent_type=None):
    """A fablepowers agent's `subagent_type` names its role outright. Anything else
    falls back to a prompt-text heuristic, which over-counts reviewers: fix-round
    dispatches to an implementer mention "review"."""
    if subagent_type in AGENT_ROLES:
        return AGENT_ROLES[subagent_type]
    p = (desc + " " + prompt[:600]).lower()
    if re.search(r"review|critique|audit|verify|spec.?check|adversarial", p):
        return "reviewer"
    if re.search(r"implement|write the code|fix the|apply|refactor|task \d|build", p):
        return "implementer"
    if re.search(r"explore|search|find|locate|map|research|investigate|analy", p):
        return "explorer"
    return "other"


def bare_skill(name):
    """`fablepowers:design-spec` -> `design-spec`; leaves unnamespaced names alone."""
    return (name or "").rsplit(":", 1)[-1]


def short_project(dirname, width=34):
    """Claude Code names a project directory after its path with the separators
    replaced by dashes. Keep the tail -- that is the part that names the project."""
    name = dirname.lstrip("-").replace("--claude-worktrees-", "/")
    return name if len(name) <= width else ".." + name[-(width - 2):]


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def scan_main(path):
    s = dict(ts=None, models=collections.Counter(), out=0, cost=0.0, skills=[], spawns=[],
             edits=0, bash_writes=0, user_turns=0, seq=[])
    for o in recs(path):
        if s["ts"] is None and o.get("timestamp"):
            s["ts"] = o["timestamp"][:10]
        m = o.get("message") or {}
        c = m.get("content")
        if o.get("type") == "user" and not o.get("isMeta"):
            t = text_of(c)
            if t.strip() and not (isinstance(c, list) and any(b.get("type") == "tool_result" for b in c if isinstance(b, dict))):
                s["user_turns"] += 1
                s["seq"].append(("user", t[:60]))
        if o.get("type") != "assistant":
            continue
        u = m.get("usage") or {}
        s["out"] += u.get("output_tokens", 0)
        s["cost"] += cost(u, m.get("model"))
        if m.get("model"):
            s["models"][m["model"]] += 1
        if not isinstance(c, list):
            continue
        for b in c:
            if b.get("type") != "tool_use":
                continue
            n, i = b.get("name"), b.get("input") or {}
            if n == "Skill":
                s["skills"].append(i.get("skill", "?")); s["seq"].append(("skill", bare_skill(i.get("skill"))))
            elif n in EDIT_TOOLS:
                s["edits"] += 1; s["seq"].append(("edit", i.get("file_path", "")))
            elif n == "Bash" and WRITE_RE.search(i.get("command", "")):
                s["bash_writes"] += 1; s["seq"].append(("edit", "bash-write"))
            elif n == "AskUserQuestion":
                s["seq"].append(("ask", ""))
            elif n in ("Agent", "Task"):
                s["spawns"].append(dict(model=i.get("model"), role=role(i.get("prompt", ""), i.get("description", ""), i.get("subagent_type"))))
    return s


def scan_subs(session_dir):
    subs = []
    for sub in glob.glob(os.path.join(session_dir, "subagents", "agent-*.jsonl")):
        ss = dict(models=collections.Counter(), out=0, cost=0.0, edits=0)
        for o in recs(sub):
            if o.get("type") != "assistant":
                continue
            m = o.get("message") or {}; u = m.get("usage") or {}
            ss["out"] += u.get("output_tokens", 0); ss["cost"] += cost(u, m.get("model"))
            if m.get("model"):
                ss["models"][m["model"]] += 1
            for b in (m.get("content") or []):
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") in EDIT_TOOLS:
                    ss["edits"] += 1
        subs.append(ss)
    return subs


def approval_gap(seq):
    """User turns between design-spec and the first implementation action (None if no design-spec)."""
    try:
        i0 = next(i for i, (k, v) in enumerate(seq) if k == "skill" and v == "design-spec")
    except StopIteration:
        return None
    after = seq[i0:]
    stop = next((i for i, (k, v) in enumerate(after)
                 if (k == "skill" and v == "implementation-plan") or (k == "edit" and not re.search(r"specs?/|plans?/|\.md$", v))), len(after))
    return sum(1 for k, _ in after[:stop] if k == "user")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--since", default=None, help="only sessions whose first timestamp is >= this date (default: all)")
    a = ap.parse_args()

    rows = []
    for main in sorted(glob.glob(os.path.join(a.projects_dir, "*", "*.jsonl"))):
        if "/memory/" in main:
            continue
        s = scan_main(main)
        if not s["ts"] or (a.since and s["ts"] < a.since):
            continue
        s["proj"] = short_project(os.path.basename(os.path.dirname(main)))
        s["subs"] = scan_subs(os.path.join(os.path.dirname(main), os.path.basename(main)[:-6]))
        rows.append(s)

    short = lambda m: (m or "?").replace("claude-", "")
    print(f"{'date':10} {'project':34} {'main':10} {'usr':>3} {'mainOut':>9} {'subOut':>8} {'sub%':>4} {'mEdit':>5} {'mBashW':>6} {'sEdit':>5} {'$main':>6} {'$sub':>5} {'apprv':>5}  sub-models | skills | spawns")
    T = collections.Counter(); sub_models = collections.Counter(); sub_out_by_model = collections.Counter(); spawn_model = collections.Counter()
    for s in rows:
        so = sum(x["out"] for x in s["subs"]); se = sum(x["edits"] for x in s["subs"]); sc = sum(x["cost"] for x in s["subs"])
        sm = collections.Counter()
        for x in s["subs"]:
            sm.update(x["models"]); sub_models.update(x["models"])
            for k in x["models"]: sub_out_by_model[k] += x["out"]
        for sp in s["spawns"]:
            spawn_model[sp["model"] or "(unset)"] += 1
        pct = f"{so / (so + s['out']):.0%}" if so + s["out"] else "-"
        mm = short(s["models"].most_common(1)[0][0]) if s["models"] else "?"
        skills = ",".join(dict.fromkeys(k.replace("superpowers:", "sp:").replace("fablepowers:", "fp:") for k in s["skills"]))
        spawns = " ".join(f"{k}x{v}" for k, v in collections.Counter(f"{x['role']}" + (f"@{x['model']}" if x["model"] else "") for x in s["spawns"]).items())
        ag = approval_gap(s["seq"]); ag = "-" if ag is None else str(ag)
        print(f"{s['ts']:10} {s['proj']:34} {mm:10} {s['user_turns']:3d} {s['out']:9,d} {so:8,d} {pct:>4} {s['edits']:5d} {s['bash_writes']:6d} {se:5d} {s['cost']:6.0f} {sc:5.0f} {ag:>5}  {' '.join(f'{short(k)}:{v}' for k, v in sm.most_common(2)):20} | {skills} | {spawns}")
        T["main_out"] += s["out"]; T["sub_out"] += so; T["main_edits"] += s["edits"]; T["main_bashw"] += s["bash_writes"]; T["sub_edits"] += se
        T["main_cost"] += s["cost"]; T["sub_cost"] += sc
        for k, v in s["models"].items():
            T["main_msgs_" + short(k)] += v

    tot = T["main_out"] + T["sub_out"]
    print(f"\nsessions: {len(rows)} (since {a.since})" if a.since else f"\nsessions: {len(rows)} (all dates)")
    print(f"output tokens: main-loop {T['main_out']:,}  subagents {T['sub_out']:,}  subagent share {T['sub_out'] / tot:.1%}" if tot else "")
    print(f"file edits: main-loop Edit/Write {T['main_edits']}  main-loop Bash writes {T['main_bashw']}  subagent Edit/Write {T['sub_edits']}")
    print(f"est. spend: main-loop ${T['main_cost']:,.0f}  subagents ${T['sub_cost']:,.0f}")
    print("Agent spawn `model` param:", dict(spawn_model))
    print("subagent output tokens by actual model:", {short(k): f"{v:,}" for k, v in sub_out_by_model.most_common()})
    print("approval-gap column: user turns between design-spec and first implementation action ('-' = no design-spec; 0 with an AskUserQuestion approval still counts as approved — check the ASK text)")


if __name__ == "__main__":
    main()
