# Claude Code harness reference

The fablepowers skills and agent bodies name actions ("dispatch the implementer seat", "ask the user a two-option question", "track tasks"). On Claude Code those actions resolve to the tools, models and mechanisms below. Other harnesses get a sibling file in this directory (`codex.md`, `opencode.md`, `pi.md`) when their phase lands.

## Actions → tools

| Action the skills name | Claude Code |
|---|---|
| Invoke a skill | Skill tool, `fablepowers:<skill>` |
| Dispatch a seat (implementer, strict implementer, reviewer) | Agent tool with `subagent_type: "fablepowers:<agent>"` — `fablepowers:implementer`, `fablepowers:strict-implementer`, `fablepowers:reviewer` |
| "Never a generic agent that inherits your model" | never the Agent tool's default `general-purpose` agent, nor an Agent call without `subagent_type` |
| Ask the user a structured question (the two-option design approval, bundled cosmetic choices) | AskUserQuestion |
| Track tasks | TodoWrite |
| Native worktree tool (create / exit) | EnterWorktree / ExitWorktree; its worktrees live under `<root>/.claude/worktrees/` and are host-owned |
| Plugin root (where `skills/`, `agents/`, `hooks/` live) | `${CLAUDE_PLUGIN_ROOT}` in hook commands; a skill's base directory is shown when the skill is invoked |

## Seats → agents and models

| Seat | Tier | Agent | Model |
|---|---|---|---|
| Implementer | frontier | `fablepowers:implementer` | opus |
| Strict implementer | mid | `fablepowers:strict-implementer` | sonnet |
| Reviewer | frontier | `fablepowers:reviewer` | opus |

The model is pinned in each agent's frontmatter (`agents/<agent>.md`), which also sets `disallowedTools: Agent` so a seat cannot spawn sub-agents. The bodies of those files are the role prompts and are harness-neutral; the frontmatter is Claude Code's. Plan headers name the seat (`implementer`, `strict-implementer`); the older values `opus` and `sonnet-strict` mean the same seats.

## Bootstrap

`hooks/hooks.json` registers a SessionStart hook (matcher `startup|clear|compact`) that runs `hooks/session-start` through a PATH-independent bash launcher. The hook injects, as `additionalContext`, a one-line preamble naming Claude Code and the Skill/Agent/`subagent_type` mapping, followed by the workflow map (`skills/workflow/SKILL.md` without its frontmatter). The whole injected context stays at or under 6,000 characters.

## Approval mechanism

_Placeholder — written in 0.4.0 Task 3: the approval gate's hook events, markers, the two approval paths (`/fablepowers:approve` and answering Approve to the design question), `/fablepowers:withdraw`, the `FABLEPOWERS_GATE=off` escape hatch, the python3 requirement and the tested-with Claude Code version._

## Report-name write guard

Claude Code refuses a subagent's write to a file whose basename is a generic report name — `report.md`, `summary.md`, `findings.md`, `analysis.md` — in any directory and any case. That is why every dispatch names a workspace path such as `reports/task-<n>.md`, and why each agent body says to return the full report inline (and not to write it through a shell command instead) when its write is refused.

## Session logs

Transcripts are JSONL files under `~/.claude/projects/<cwd>/`, where `<cwd>` is the session's working directory with every `/` and `.` replaced by `-`. The main session is `<session-id>.jsonl`; subagents dispatched from it are `<session-id>/subagents/agent-<id>.jsonl` (with a `.meta.json` beside each). Agents run with worktree isolation start with `cwd` under `<repo>/.claude/worktrees/agent-<id>`.

## Other harnesses (planned)

Not supported yet; defaults recorded for the phases that add them:

- **Codex (0.5.0):** implementer Sol, strict implementer Terra, reviewer Sol. Exact model ids are confirmed in 0.5.0, and a per-user override is required, since not every account has Sol.
- **OpenCode (0.6.0)** and **Pi (0.7.0):** each gets its own design and reference file.
