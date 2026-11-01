#!/usr/bin/env python3
"""Subagent concurrency timeline for Claude Code session transcripts.

Answers one question: while this session's subagents ran, how many ran at once?

Claude Code writes a session's main transcript as `<session>.jsonl` and each
subagent it dispatched as `<session>/subagents/agent-<id>.jsonl`, with an
`agent-<id>.meta.json` beside it (`agentType`, `description`, `toolUseId`). This
script reads only the subagent files. Per session it reports:

  * agent count, active agent-hours, and wall-hours with at least one agent active
  * average concurrency (active / wall) and peak concurrency
  * per agent: first timestamp, active minutes, type, description

"Active" time joins consecutive timestamps of one agent that are 10 minutes or
less apart; a longer gap ends one interval and starts the next, so an agent idle
on a permission prompt or a long tool call does not count while it sits. Peak is
the most intervals overlapping at one instant. An agent with no timestamped line
is skipped; a session with no subagents reports zeros.

Usage:
    python3 -I scripts/session-timeline.py [--json] <session.jsonl> [<session.jsonl> ...]

--json prints one JSON object per session per line, with the fields `session`,
`title`, `agents`, `active_hours`, `wall_hours`, `avg_concurrency`, `peak` and
`intervals`; each interval has `agent_id`, `tool_use_id` (null when the meta file
has none), `type`, `description` and `segments` ([start_iso, end_iso] pairs).
A missing transcript exits 2 before anything is printed.

Stdlib only.
"""
import argparse, datetime, glob, json, os, sys

GAP = datetime.timedelta(minutes=10)


def recs(path):
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def parse_ts(value):
    if not isinstance(value, str):
        return None
    try:
        t = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    return t.astimezone(datetime.timezone.utc)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % (t.microsecond // 1000)


def segments(times):
    """Timestamps -> [start, end] runs whose consecutive gaps are all <= GAP."""
    segs = []
    for t in sorted(times):
        if segs and t - segs[-1][1] <= GAP:
            segs[-1][1] = t
        else:
            segs.append([t, t])
    return segs


def load_json(path):
    try:
        with open(path, errors="replace") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def agents(session_dir):
    out = []
    for path in sorted(glob.glob(os.path.join(session_dir, "subagents", "agent-*.jsonl"))):
        base = os.path.basename(path)[:-len(".jsonl")]
        times = [t for t in (parse_ts(r.get("timestamp")) for r in recs(path) if isinstance(r, dict)) if t]
        if not times:
            continue
        meta = load_json(os.path.join(os.path.dirname(path), base + ".meta.json"))
        out.append({"agent_id": base[len("agent-"):],
                    "tool_use_id": meta.get("toolUseId"),
                    "type": meta.get("agentType") or "?",
                    "description": meta.get("description") or "",
                    "segs": segments(times)})
    out.sort(key=lambda a: a["segs"][0][0])
    return out


def wall(all_segs):
    """Length of the union of all segments."""
    total, cur = datetime.timedelta(0), None
    for s, e in sorted(all_segs):
        if cur and s <= cur[1]:
            cur[1] = max(cur[1], e)
            continue
        if cur:
            total += cur[1] - cur[0]
        cur = [s, e]
    if cur:
        total += cur[1] - cur[0]
    return total


def peak(all_segs):
    """Most segments covering one instant. A segment covers [start, end), so one
    ending as another starts is not an overlap; a zero-length segment still
    counts at its own instant."""
    best = 0
    for i, (s, _) in enumerate(all_segs):
        n = sum(1 for j, (s2, e2) in enumerate(all_segs) if j == i or s2 <= s < e2)
        best = max(best, n)
    return best


def summarize(transcript):
    session_dir = transcript[:-len(".jsonl")] if transcript.endswith(".jsonl") else transcript
    session_id = os.path.basename(session_dir)
    title = load_json(os.path.join(session_dir, "custom-title.json")).get("customTitle") or session_id
    ags = agents(session_dir)
    all_segs = [seg for a in ags for seg in a["segs"]]
    active = sum((e - s for s, e in all_segs), datetime.timedelta(0)).total_seconds() / 3600
    wall_h = wall(all_segs).total_seconds() / 3600
    summary = {"session": session_id, "title": title, "agents": len(ags),
               "active_hours": round(active, 4), "wall_hours": round(wall_h, 4),
               "avg_concurrency": round(active / wall_h, 4) if wall_h else 0.0,
               "peak": peak(all_segs),
               "intervals": [{"agent_id": a["agent_id"], "tool_use_id": a["tool_use_id"],
                              "type": a["type"], "description": a["description"],
                              "segments": [[iso(s), iso(e)] for s, e in a["segs"]]} for a in ags]}
    return summary, ags


def main():
    ap = argparse.ArgumentParser(description="Subagent concurrency per session transcript.")
    ap.add_argument("--json", action="store_true", help="one JSON object per session per line")
    ap.add_argument("transcripts", nargs="+", metavar="session.jsonl")
    args = ap.parse_args()
    missing = [p for p in args.transcripts if not os.path.isfile(p)]
    if missing:
        for p in missing:
            print("session-timeline: no such file: %s" % p, file=sys.stderr)
        return 2
    for path in args.transcripts:
        s, ags = summarize(path)
        if args.json:
            print(json.dumps(s))
            continue
        print("%s: agents=%d active_hours=%.2f wall_hours=%.2f avg_concurrency=%.2f peak=%d"
              % (s["title"], s["agents"], s["active_hours"], s["wall_hours"], s["avg_concurrency"], s["peak"]))
        for a in ags:
            mins = sum((e - st).total_seconds() for st, e in a["segs"]) / 60
            print("  %s  %6.1f min  %s  %s" % (iso(a["segs"][0][0]), mins, a["type"], a["description"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
