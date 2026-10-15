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

The design-approval checkpoint is enforced by a hook, `hooks/approval-gate` (a PATH-independent bash launcher) running `hooks/approval_gate.py`. Tested with Claude Code 2.1.299; treat that as the minimum, since the approve and withdraw commands rely on the `UserPromptExpansion` hook event.

**Markers.** Per design, in `<toplevel>/.fablepowers/<key>/`, where `<toplevel>` is the nearest ancestor of the hook's `cwd` holding `.git` and `<key>` is the spec's basename without `.md`. The gate is inert outside a git repo.

- `pending` (`{"spec", "created"}`) is written by the hook when the main session creates a new file `docs/specs/<name>.md` with the Write tool. design-spec therefore creates the spec with Write, never a Bash redirect or heredoc: the gate sees only a Write create, so a spec written through Bash is never gated. Overwrites, subagent writes, nested directories and specs kept outside `docs/specs/` do not pend. `docs/specs/` is for designs only: any new file there starts an approval, so put other notes elsewhere, and `/fablepowers:withdraw` clears a stray one.
- `approved` (`{"spec", "approved_at", "via": "command"|"question", "spec_sha256"}`) is written by the hook on a user action only. `pending` stays beside it as an audit record; the hash is recorded, not enforced.
- A design is pending while `pending` is a regular file and there is no valid `approved` (a regular, non-symlink file holding that JSON). A directory, symlink or malformed file named `approved` does not approve; it is logged to `.fablepowers/gate.log`.

**What it blocks** (PreToolUse, `permissionDecision: "deny"` with a reason that names the pending keys and both commands):

- While any design is pending: an Agent call with `subagent_type` `fablepowers:implementer` or `fablepowers:strict-implementer`, and Write, Edit, MultiEdit or NotebookEdit on a path inside the toplevel outside `docs/specs/`, `docs/plans/` and `.fablepowers/`. Paths are resolved with symlinks and `..` before the check. Reviewer dispatch and paths outside the repo are allowed, except Claude Code settings files.
- While any design is pending: Write, Edit, MultiEdit or NotebookEdit on any Claude Code settings file, `.claude/settings.json` or `.claude/settings.local.json`, wherever it is (the repo, `~/.claude`, any other directory). The path's last two components are matched on the path as given and after resolving symlinks, compared like marker names (case-insensitively and as NTFS resolves them). The reason names the pending design. This keeps the edit tools from installing a hook that answers the approval question.
- Always: Write, Edit, MultiEdit or NotebookEdit on a path with a component named `pending` or `approved` under a `.fablepowers` component. Names compare case-insensitively and as NTFS resolves them (trailing dots and spaces, and `:stream` suffixes, are ignored).

**Approving.** Two user actions, and only these, write `approved`:

- `/fablepowers:approve [key or spec path]`, recorded on the `UserPromptExpansion` event. One pending design needs no argument; with several, a missing or unknown argument blocks the command and lists the keys, and nothing is recorded. The approve and withdraw skills set `disable-model-invocation: true`, which makes Claude Code refuse the model's own Skill call before any hook runs. That setting is what keeps the model from approving itself, and a test asserts it.
- Answering **Approve** to the design question (AskUserQuestion), recorded on PostToolUse from `tool_response.answers`. It counts only when the question's options are exactly Approve and Changes needed and exactly one design is pending with its spec file present. Otherwise the hook tells the model and the user why it recorded nothing, and which command to run. Changes needed records nothing; the design stays pending.

**Withdrawing.** `/fablepowers:withdraw [key or spec path]` removes `pending` for an abandoned design (same argument rules). The spec file stays.

**Escape hatch.** `FABLEPOWERS_GATE=off` in the environment: nothing is denied, and each would-be denial is appended to `.fablepowers/gate.log`. Malformed payloads and internal errors also allow and are logged there.

**Python.** The gate needs Python 3.8+ (stdlib only, run with `-I`). The launcher uses `$FABLEPOWERS_PYTHON` when set (then it is the only candidate), else `python3` on PATH, then `/usr/bin/python3`, `/usr/local/bin/python3`, `/opt/homebrew/bin/python3`. With no usable python the gate is disabled and allows everything. In a repository whose `.fablepowers/` exists it shows the warning `fablepowers approval gate disabled: python3 not found` once per session; elsewhere (repositories without `.fablepowers/`, and outside git) it stays silent, since without python no design can become pending there.

**Accepted gap: shell writes.** The gate watches the edit tools and the dispatch, not shell commands. Through a shell command the model could forge or delete markers (including creating a directory named like one), write a spec without pending it, or write a hook into a settings file. Such a hook could auto-answer the approval question: Claude Code lets a PreToolUse hook fill in AskUserQuestion's answers, and the result is indistinguishable from a user's. While a design is pending, its edit tools are blocked from repo code and from Claude Code settings files in any location; its shell is not. The gate stops a session rolling past approval; it is not a sandbox.

## Report-name write guard

Claude Code refuses a subagent's write to a file whose basename is a generic report name — `report.md`, `summary.md`, `findings.md`, `analysis.md` — in any directory and any case. That is why every dispatch names a workspace path such as `reports/task-<n>.md`, and why each agent body says to return the full report inline (and not to write it through a shell command instead) when its write is refused.

## Session logs

Transcripts are JSONL files under `~/.claude/projects/<cwd>/`, where `<cwd>` is the session's working directory with every `/` and `.` replaced by `-`. The main session is `<session-id>.jsonl`; subagents dispatched from it are `<session-id>/subagents/agent-<id>.jsonl` (with a `.meta.json` beside each). Agents run with worktree isolation start with `cwd` under `<repo>/.claude/worktrees/agent-<id>`.

## Other harnesses (planned)

Not supported yet; defaults recorded for the phases that add them:

- **Codex (0.5.0):** implementer Sol, strict implementer Terra, reviewer Sol. Exact model ids are confirmed in 0.5.0, and a per-user override is required, since not every account has Sol.
- **OpenCode (0.6.0)** and **Pi (0.7.0):** each gets its own design and reference file.
