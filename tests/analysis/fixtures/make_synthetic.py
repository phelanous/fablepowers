#!/usr/bin/env python3
"""Writes the synthetic session fixtures of tests/analysis/fixtures/ (deterministic).

Synthetic records cover what the sanitised real logs lack: the whole Claude Code
set, and on Codex / OpenCode / Pi the design-spec approval gap, costs >= $1,
OpenCode depth-2 children and resume calls, orphan children, a truncated Codex
line, a `.jsonl.zst` rollout, Pi's default `--<cwd>--` layout, Pi command
approvals (approved / withdrew / not recorded) and a Pi child found only through
the `fablepowers-children/<parent-id>/` directory. The expected values for every
record are derived by hand in README.md.

Usage: python3 tests/analysis/fixtures/make_synthetic.py   (rewrites the files)
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))


def write_jsonl(rel, records, tail=None):
    p = os.path.join(HERE, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as fh:
        for r in records:
            fh.write(json.dumps(r, separators=(",", ":")) + "\n")
        if tail is not None:
            fh.write(tail)

# ------------------------------------------------------------------ Claude Code


def cu(ts, content, **kw):
    return dict(type="user", timestamp=ts, message=dict(role="user", content=content), **kw)


def ca(ts, model, usage, blocks):
    return dict(type="assistant", timestamp=ts, message=dict(role="assistant", model=model, usage=usage, content=blocks))


def tool(name, **inp):
    return dict(type="tool_use", id="toolu_" + name.lower(), name=name, input=inp)


def claude():
    beta = "claude/projects/-fixture-beta--claude-worktrees-feat-x/"
    alpha = "claude/projects/-fixture-alpha/"
    d = "2026-10-07T09:%02d:00.000Z"
    write_jsonl(beta + "c3.jsonl", [
        dict(type="summary", summary="placeholder text"),
        cu(d % 0, "placeholder text"),
        ca(d % 1, "claude-opus-5", dict(input_tokens=200000, output_tokens=40000),
           [tool("Skill", skill="fablepowers:design-spec")]),
        cu(d % 2, [dict(type="tool_result", tool_use_id="toolu_skill", content="placeholder text")]),
        cu(d % 3, "placeholder text", isMeta=True),
        ca(d % 4, "claude-fable-5", dict(cache_creation_input_tokens=80000, output_tokens=10000),
           [tool("AskUserQuestion", questions=[dict(question="placeholder text")])]),
        cu(d % 5, "placeholder text"),
        ca(d % 6, "claude-opus-5", dict(cache_read_input_tokens=1000000, output_tokens=4000),
           [tool("Write", file_path="/fixture/beta/docs/specs/f1.md", content="placeholder text"),
            tool("Agent", model="sonnet", subagent_type="fablepowers:implementer", prompt="placeholder text",
                 description="placeholder"),
            tool("Agent", subagent_type="fablepowers:reviewer", prompt="placeholder text", description="placeholder"),
            tool("Task", prompt="explore placeholder", description="placeholder")]),
        cu(d % 7, "/fablepowers:approve"),
        ca(d % 8, "claude-fable-5", dict(output_tokens=3000),
           [tool("Bash", command="cat > out.py <<'EOF'"), tool("Edit", file_path="/fixture/beta/src/f2.py")]),
        cu(d % 9, "placeholder text"),
    ])
    s = "2026-10-07T09:30:%02d.000Z"
    write_jsonl(beta + "c3/subagents/agent-a.jsonl", [
        cu(s % 0, "placeholder text"),
        ca(s % 1, "claude-sonnet-5", dict(input_tokens=1000000, output_tokens=6000),
           [tool("Edit", file_path="/fixture/beta/src/f2.py"), tool("Write", file_path="/fixture/beta/src/f3.py")]),
    ])
    write_jsonl(beta + "c3/subagents/agent-b.jsonl", [
        ca(s % 2, "claude-haiku-4-5-20251001", dict(output_tokens=2000),
           [tool("MultiEdit", file_path="/fixture/beta/src/f2.py")]),
    ])
    write_jsonl(beta + "c3/subagents/agent-c.jsonl", [
        ca(s % 3, "claude-opus-5", dict(output_tokens=1000), [tool("Read", file_path="/fixture/beta/src/f2.py")]),
    ])
    a = "2026-10-12T14:%02d:00.000Z"
    write_jsonl(alpha + "a1.jsonl", [
        cu(a % 0, "placeholder text"),
        ca(a % 1, "claude-sonnet-5", dict(input_tokens=50000, output_tokens=1500),
           [tool("Skill", skill="fablepowers:verify-done"), tool("Skill", skill="superpowers:brainstorming"),
            tool("Skill", skill="fablepowers:verify-done")]),
        cu(a % 2, "placeholder text"),
        ca(a % 3, "claude-sonnet-5", dict(output_tokens=500), [tool("Bash", command="ls -la")]),
    ])
    b = "2026-10-03T08:%02d:00.000Z"
    write_jsonl(alpha + "b2.jsonl", [
        cu(b % 0, "placeholder text"),
        ca(b % 1, "gpt-unknown", dict(output_tokens=700),
           [tool("Skill", skill="design-spec"), tool("Skill", skill="fablepowers:implementation-plan")]),
    ])
    write_jsonl(alpha + "b2/subagents/agent-z.jsonl", [cu(b % 2, "placeholder text")])
    write_jsonl(alpha + "empty.jsonl", [dict(type="summary", summary="placeholder text")])
    write_jsonl("claude/projects/memory/m1.jsonl", [cu("2026-10-05T00:00:00.000Z", "placeholder text")])

# ------------------------------------------------------------------ Codex

CX_ROOT = "01a1fe00-0000-7000-8000-000000000001"
CX_CHILD = "01a1fe00-0000-7000-8000-000000000002"
CX_ORPHAN = "01a1fe00-0000-7000-8000-000000000003"
CX_MISSING = "01a1fe00-0000-7000-8000-0000000000ff"


def cxr(ts, typ, payload):
    return dict(timestamp=ts, type=typ, payload=payload)


def cx_meta(ts, tid, source):
    return cxr(ts, "session_meta", dict(session_id=tid, id=tid, timestamp=ts, cwd="/fixture/cx-synth", originator="codex_exec",
                                        cli_version="0.162.1", source=source, model_provider="openai"))


def cx_item(ts, tid, item):
    return cxr(ts, "event_msg", dict(type="item_completed", thread_id=tid, turn_id="t1", item=item))


def cx_user(ts, tid, n):
    return cx_item(ts, tid, dict(type="UserMessage", id="um%d" % n, content=[dict(type="text", text="placeholder text")]))


def cx_tokens(ts, tid, out, thread_out):
    u = dict(input_tokens=1000, cached_input_tokens=0, cache_write_input_tokens=0, output_tokens=out,
             reasoning_output_tokens=0, total_tokens=1000 + out)
    t = dict(u, output_tokens=thread_out, total_tokens=1000 + thread_out)
    return cxr(ts, "token_usage_record", dict(thread_id=tid, turn_id="t1", session_id=tid, usage=u, turn_token_usage=u,
                                               thread_token_usage=t))


def cx_cmd(ts, tid, n, cmd):
    return cx_item(ts, tid, dict(type="CommandExecution", id="ce%d" % n, process_id="1", command=["/usr/bin/bash", "-lc", cmd],
                                 cwd="/fixture/cx-synth", source="unified_exec_startup", status="completed", exit_code=0))


def cx_fc(ts, tid, n, path, kind="add"):
    return cx_item(ts, tid, dict(type="FileChange", id="fc%d" % n, changes={path: dict(type=kind)}, status="completed"))


def codex():
    t = "2026-10-18T10:%02d:00.000Z"
    tc = cxr(t % 0, "turn_context", dict(turn_id="t1", cwd="/fixture/cx-synth", model="gpt-6-sol", effort="medium",
                                         approval_policy="never"))
    recs = [
        cx_meta(t % 0, CX_ROOT, "exec"), tc,
        cxr(t % 0, "response_item", dict(type="message", role="user", content=[dict(type="input_text", text="placeholder text")],
                                         internal_chat_message_metadata_passthrough=dict(
                                             content_item_kinds=["environments.environment_context"]))),
        cx_user(t % 1, CX_ROOT, 1),
        cx_cmd(t % 2, CX_ROOT, 1, "cat /fixture/plugins/fablepowers/skills/design-spec/SKILL.md"),
        cx_tokens(t % 2, CX_ROOT, 300, 300),
        cx_user(t % 3, CX_ROOT, 2),
        cxr(t % 3, "response_item", dict(type="function_call", name="request_user_input", call_id="c1",
                                         arguments=json.dumps(dict(questions=[dict(question="placeholder text")])))),
        cx_user(t % 4, CX_ROOT, 3),
        cx_fc(t % 4, CX_ROOT, 1, "/fixture/cx-synth/docs/specs/f1.md"),
        cx_tokens(t % 4, CX_ROOT, 200, 500),
        cx_user(t % 5, CX_ROOT, 4),
        cxr(t % 5, "response_item", dict(type="function_call", namespace="collaboration", name="spawn_agent", call_id="c2",
                                         arguments=json.dumps(dict(task_name="fablepowers_reviewer_s1", model="gpt-6-luna",
                                                                   reasoning_effort="low", fork_turns="none", message="x")))),
        cx_cmd(t % 6, CX_ROOT, 2, "cat > /fixture/cx-synth/out.txt"),
        cx_fc(t % 7, CX_ROOT, 2, "/fixture/cx-synth/src/f2.py", "update"),
        cx_tokens(t % 7, CX_ROOT, 100, 600),
        cx_user(t % 8, CX_ROOT, 5),
    ]
    write_jsonl("codex/sessions/2026/10/18/rollout-2026-10-18T10-00-00-%s.jsonl" % CX_ROOT, recs,
                tail='{"timestamp":"2026-10-18T10:09:00.000Z","type":"event_msg","payload":{"type":"item_comp')
    c = "2026-10-18T10:05:%02d.000Z"
    write_jsonl("codex/sessions/2026/10/18/rollout-2026-10-18T10-05-01-%s.jsonl" % CX_CHILD, [
        cx_meta(c % 1, CX_CHILD, dict(subagent=dict(thread_spawn=dict(parent_thread_id=CX_ROOT, depth=1,
                                                                      agent_path="/root/fablepowers_reviewer_s1",
                                                                      agent_nickname="Fixture", agent_role=None)))),
        cxr(c % 1, "turn_context", dict(turn_id="t1", cwd="/fixture/cx-synth", model="gpt-6-luna", effort="low")),
        cx_fc(c % 2, CX_CHILD, 1, "/fixture/cx-synth/src/f3.py"),
        cx_cmd(c % 3, CX_CHILD, 1, "sed -i s/a/b/ /fixture/cx-synth/src/f3.py"),
        cx_tokens(c % 4, CX_CHILD, 400, 400),
        cx_tokens(c % 5, CX_CHILD, 50, 450),
    ])
    o = "2026-10-18T11:00:%02d.000Z"
    write_jsonl("codex/sessions/2026/10/18/rollout-2026-10-18T11-00-00-%s.jsonl" % CX_ORPHAN, [
        cx_meta(o % 0, CX_ORPHAN, dict(subagent=dict(thread_spawn=dict(parent_thread_id=CX_MISSING, depth=1,
                                                                       agent_path="/root/fablepowers_implementer_s9",
                                                                       agent_nickname="Orphan", agent_role=None)))),
        cxr(o % 0, "turn_context", dict(turn_id="t1", cwd="/fixture/cx-synth", model="gpt-6-luna", effort="low")),
        cx_tokens(o % 1, CX_ORPHAN, 70, 70),
    ])
    p = os.path.join(HERE, "codex/sessions/2026/10/18/rollout-2026-10-18T12-00-00-01a1fe00-0000-7000-8000-000000000004.jsonl.zst")
    with open(p, "wb") as fh:
        fh.write(b"\x28\xb5\x2f\xfd" + b"\x00" * 12)

# ------------------------------------------------------------------ OpenCode

OC_ROOT = "ses_fixture000000ocRootGap0001"
OC_C1 = "ses_fixture000000ocChildImpl001"
OC_GC = "ses_fixture000000ocGrandchild01"
OC_C2 = "ses_fixture000000ocChildGenrl01"
OC_C3 = "ses_fixture000000ocChildRevw001"
OC_ORPH = "ses_fixture000000ocOrphan00001"
OC_GONE = "ses_fixture000000ocMissingPar01"
T0 = 1792281600000  # 2026-10-18T00:00:00Z (ms)


def q(v):
    if v is None:
        return "NULL"
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("'", "''") + "'"


def oc_session(sid, parent, agent, model, t, cost, out, reasoning):
    cols = dict(id=sid, project_id="prj_fixture_synth", parent_id=parent, slug="fixture-" + sid[-6:].lower(),
                directory="/fixture/oc-synth", title="placeholder text", version="2.0.29", cost=cost, tokens_input=1000,
                tokens_output=out, tokens_reasoning=reasoning, tokens_cache_read=0, tokens_cache_write=0, agent=agent,
                model=json.dumps(dict(id=model, providerID="opencode"), separators=(",", ":")),
                time_created=t, time_updated=t + 1000, resume_attempts=0)
    return "INSERT INTO session_v2 (%s) VALUES (%s);" % (", ".join(cols), ", ".join(q(v) for v in cols.values()))


def oc_msg(sid, seq, typ, data, t):
    return "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES (%s);" % ", ".join(
        q(v) for v in ("msg_%s_%02d" % (sid[-10:], seq), sid, typ, seq, t, t, json.dumps(data, separators=(",", ":"))))


def oc_tool(name, inp, status="completed", md=None):
    st = dict(status=status, input=inp)
    if md is not None:
        st["metadata"] = md
    return dict(type="tool", id="call_" + name, name=name, executed=True, state=st)


def oc_asst(model, out, reasoning, cost, tools=(), agent="build"):
    return dict(agent=agent, model=dict(id=model, providerID="opencode"), finish="tool-calls", cost=cost,
                content=[dict(type="text", text="placeholder text")] + list(tools),
                tokens=dict(input=1000, output=out, reasoning=reasoning, cache=dict(read=0, write=0)))


def opencode():
    L = ["-- synthetic OpenCode rows (tests/analysis/fixtures/make_synthetic.py); load after sanitised.sql",
         "BEGIN TRANSACTION;",
         "INSERT INTO project (id, worktree, vcs, name, time_created, time_updated, time_active, sandboxes) VALUES "
         "('prj_fixture_synth', '/fixture/oc-synth', 'git', 'oc-synth', 0, 0, 0, '[]');",
         # session_v2 totals deliberately differ from the session_message sums
         oc_session(OC_ROOT, None, None, "big-pickle", T0 + 3600000, 9.99, 999, 111),
         oc_session(OC_C1, OC_ROOT, "fablepowers-implementer", "deepseek-v4.1-flash-free", T0 + 3660000, 0.0, 1, 1),
         oc_session(OC_GC, OC_C1, "general", "big-pickle", T0 + 3690000, 0.0, 1, 1),
         oc_session(OC_C2, OC_ROOT, "general", "big-pickle", T0 + 3720000, 0.0, 1, 1),
         oc_session(OC_C3, OC_ROOT, "fablepowers-reviewer", "cat-jam-free", T0 + 3780000, 0.0, 1, 1),
         oc_session(OC_ORPH, OC_GONE, "fablepowers-reviewer", "cat-jam-free", T0 + 7200000, 0.0, 1, 1)]
    t = T0 + 3600000
    root = [
        (1, "user", dict(text="placeholder text")),
        (2, "assistant", oc_asst("big-pickle", 100, 40, 1.25, [oc_tool("skill", dict(id="fablepowers:design-spec"))])),
        (3, "synthetic", dict(text="placeholder text")),
        (4, "user", dict(text="placeholder text")),
        (5, "assistant", oc_asst("big-pickle", 50, 10, 0.5, [
            oc_tool("question", dict(questions=[dict(question="placeholder text")]), md=dict(answers=[["a"]])),
            oc_tool("write", dict(path="/fixture/oc-synth/docs/specs/f1.md"))])),
        (6, "user", dict(text="/fablepowers:approve")),
        (7, "assistant", oc_asst("big-pickle", 70, 30, 0.75, [
            oc_tool("subagent", dict(agent="fablepowers-implementer", description="placeholder", prompt="placeholder"),
                    md=dict(sessionID=OC_C1)),
            oc_tool("edit", dict(path="/fixture/oc-synth/src/f2.py")),
            oc_tool("shell", dict(command="cat > /fixture/oc-synth/out.txt"))])),
        (8, "assistant", oc_asst("gpt-oss-fixture", 20, 5, 0.0, [
            oc_tool("subagent", dict(agent="fablepowers-implementer", description="placeholder", prompt="placeholder",
                                     sessionID=OC_C1), md=dict(sessionID=OC_C1)),
            oc_tool("subagent", dict(agent="general", description="review placeholder", prompt="review placeholder"),
                    md=dict(sessionID=OC_C2)),
            oc_tool("subagent", dict(agent="fablepowers-reviewer", description="placeholder", prompt="placeholder",
                                     model="opencode/cat-jam-free"), md=dict(sessionID=OC_C3))])),
        (9, "idle", dict(outcome="completed")),
        (10, "user", dict(text="placeholder text")),
    ]
    # inserted out of seq order: a reader must ORDER BY seq
    for seq, typ, data in sorted(root, key=lambda r: (r[0] % 3, r[0])):
        data = dict(data, time=dict(created=t + seq * 1000))
        L.append(oc_msg(OC_ROOT, seq, typ, data, t + seq * 1000))
    kids = {
        OC_C1: [(1, "user", dict(text="placeholder text")),
                (2, "assistant", oc_asst("deepseek-v4.1-flash-free", 200, 50, 1.5, [
                    oc_tool("write", dict(path="/fixture/oc-synth/src/f3.py")),
                    oc_tool("edit", dict(path="/fixture/oc-synth/src/f3.py")),
                    oc_tool("shell", dict(command="sed -i s/a/b/ /fixture/oc-synth/src/f3.py")),
                    oc_tool("subagent", dict(agent="general", description="placeholder", prompt="placeholder"),
                            md=dict(sessionID=OC_GC))], agent="fablepowers-implementer"))],
        OC_GC: [(1, "user", dict(text="placeholder text")),
                (2, "assistant", oc_asst("big-pickle", 30, 0, 0.25, [oc_tool("edit", dict(path="/fixture/oc-synth/src/f4.py"))],
                                         agent="general"))],
        OC_C2: [(1, "user", dict(text="placeholder text")),
                (2, "assistant", oc_asst("big-pickle", 10, 0, 0.0, agent="general"))],
        OC_C3: [(1, "user", dict(text="placeholder text")),
                (2, "assistant", oc_asst("cat-jam-free", 40, 10, 1.0, [oc_tool("read", dict(path="/fixture/oc-synth/src/f3.py"))],
                                         agent="fablepowers-reviewer"))],
        OC_ORPH: [(1, "user", dict(text="placeholder text")),
                  (2, "assistant", oc_asst("cat-jam-free", 60, 0, 1.0, agent="fablepowers-reviewer"))],
    }
    for sid, msgs in kids.items():
        for seq, typ, data in msgs:
            L.append(oc_msg(sid, seq, typ, dict(data, time=dict(created=t + 100000 + seq)), t + 100000 + seq))
    L.append("COMMIT;")
    with open(os.path.join(HERE, "opencode/synthetic.sql"), "w") as fh:
        fh.write("\n".join(L) + "\n")

# ------------------------------------------------------------------ Pi

PI_DIR = "pi/default/--fixture-pi-synth--/"
PI_ROOT = "01a1fe10-0000-7000-8000-000000000001"
PI_C1 = "01a1fe10-0000-7000-8000-000000000002"
PI_C2 = "01a1fe10-0000-7000-8000-000000000003"
PI_ORPH = "01a1fe10-0000-7000-8000-000000000004"
PI_GONE = "01a1fe10-0000-7000-8000-0000000000ff"


class Tree:
    """Pi entries are an id/parentId chain."""

    def __init__(self):
        self.n, self.last = 0, None

    def e(self, ts, typ, **kw):
        self.n += 1
        eid = "e%07d" % self.n
        r = dict(type=typ, id=eid, parentId=self.last, timestamp=ts, **kw)
        self.last = eid
        return r


def pi_usage(out, reasoning, cost):
    return dict(input=1000, output=out, cacheRead=0, cacheWrite=0, reasoning=reasoning, totalTokens=1000 + out,
                cost=dict(input=0.0, output=cost, cacheRead=0, cacheWrite=0, total=cost))


def pi_asst(tr, ts, model, out, reasoning, cost, calls):
    content = [dict(type="text", text="placeholder text")] + [
        dict(type="toolCall", id="call_%s_%d" % (n, i), name=n, arguments=a) for i, (n, a) in enumerate(calls)]
    return tr.e(ts, "message", message=dict(role="assistant", content=content, api="openai-completions", provider="openrouter",
                                            model=model, usage=pi_usage(out, reasoning, cost), stopReason="toolUse"))


def pi_user(tr, ts, text):
    return tr.e(ts, "message", message=dict(role="user", content=[dict(type="text", text=text)]))


def pi_result(tr, ts, text):
    return tr.e(ts, "custom_message", customType="fablepowers-result", content=text, display=True)


def pi():
    t = "2026-10-18T13:%02d:00.000Z"
    tr = Tree()
    ds = "/fixture/plugins/fablepowers/pi/skills/fablepowers-design-spec/SKILL.md"
    recs = [
        dict(type="session", version=3, id=PI_ROOT, timestamp=t % 0, cwd="/fixture/pi-synth"),
        tr.e(t % 0, "model_change", provider="openrouter", modelId="deepseek/deepseek-v4-flash"),
        pi_user(tr, t % 1, "placeholder text"),
        pi_asst(tr, t % 2, "deepseek/deepseek-v4-flash", 100, 30, 1.1,
                [("read", dict(path=ds)), ("read", dict(path="/fixture/plugins/fablepowers/skills/design-spec/SKILL.md"))]),
        pi_user(tr, t % 3, "placeholder text"),
        pi_asst(tr, t % 4, "deepseek/deepseek-v4-flash", 50, 0, 0.4,
                [("fablepowers_ask_approval", dict()), ("write", dict(path="/fixture/pi-synth/docs/specs/f1.md"))]),
        pi_result(tr, t % 5, "fablepowers approval gate: the user withdrew design `docs/specs/f1.md` (key `k1`); "
                              "the approval is withdrawn."),
        pi_result(tr, t % 6, "fablepowers approval gate: `/fablepowers:approve` may not have been recorded: placeholder."),
        pi_result(tr, t % 7, "fablepowers approval gate: the user approved design `docs/specs/f1.md` (key `k1`); "
                              "the approval is recorded."),
        pi_user(tr, t % 8, '<skill name="fablepowers-verify-done" location="/fixture/plugins/fablepowers/pi/skills/'
                           'fablepowers-verify-done/SKILL.md"></skill>\nplaceholder text'),
        pi_asst(tr, t % 9, "deepseek/deepseek-v4-flash", 80, 20, 0.75,
                [("fablepowers_dispatch", dict(seat="implementer", task="implement placeholder")),
                 ("bash", dict(command="cat > /fixture/pi-synth/out.txt"))]),
        tr.e(t % 10, "custom", customType="fablepowers-child",
             data=dict(seat="implementer", childSessionId=PI_C1, model="openrouter/qwen/qwen3.6-flash", exitCode=0)),
        tr.e(t % 10, "message", message=dict(role="toolResult", toolCallId="call_fablepowers_dispatch_0",
                                             toolName="fablepowers_dispatch", content=[dict(type="text", text="placeholder text")],
                                             isError=False)),
        pi_asst(tr, t % 11, "deepseek/deepseek-v4-flash", 20, 0, 0.0,
                [("edit", dict(path="/fixture/pi-synth/src/f2.py")),
                 ("fablepowers_dispatch", dict(seat="reviewer", task="review placeholder"))]),
    ]
    write_jsonl(PI_DIR + "2026-10-18T13-00-00-000Z_%s.jsonl" % PI_ROOT, recs)
    kid = PI_DIR + "fablepowers-children/%s/" % PI_ROOT
    tr = Tree()
    write_jsonl(kid + "2026-10-18T13-09-30-000Z_%s.jsonl" % PI_C1, [
        dict(type="session", version=3, id=PI_C1, timestamp="2026-10-18T13:09:30.000Z", cwd="/fixture/pi-synth"),
        pi_user(tr, "2026-10-18T13:09:31.000Z", "placeholder text"),
        pi_asst(tr, "2026-10-18T13:09:40.000Z", "qwen/qwen3.6-flash", 300, 100, 2.2,
                [("write", dict(path="/fixture/pi-synth/src/f3.py")), ("edit", dict(path="/fixture/pi-synth/src/f3.py")),
                 ("bash", dict(command="sed -i s/a/b/ /fixture/pi-synth/src/f3.py"))]),
    ])
    tr = Tree()
    write_jsonl(kid + "2026-10-18T13-11-30-000Z_%s.jsonl" % PI_C2, [
        dict(type="session", version=3, id=PI_C2, timestamp="2026-10-18T13:11:30.000Z", cwd="/fixture/pi-synth"),
        pi_user(tr, "2026-10-18T13:11:31.000Z", "placeholder text"),
        pi_asst(tr, "2026-10-18T13:11:40.000Z", "google/gemini-3.1-flash-lite", 40, 0, 1.05, []),
    ])
    tr = Tree()
    write_jsonl(PI_DIR + "fablepowers-children/%s/2026-10-18T14-00-00-000Z_%s.jsonl" % (PI_GONE, PI_ORPH), [
        dict(type="session", version=3, id=PI_ORPH, timestamp="2026-10-18T14:00:00.000Z", cwd="/fixture/pi-synth"),
        pi_user(tr, "2026-10-18T14:00:01.000Z", "placeholder text"),
        pi_asst(tr, "2026-10-18T14:00:10.000Z", "qwen/qwen3.6-flash", 60, 0, 1.0, []),
    ])
    with open(os.path.join(HERE, PI_DIR + "notes.txt"), "w") as fh:
        fh.write("not a session file\n")


if __name__ == "__main__":
    claude(); codex(); opencode(); pi()
