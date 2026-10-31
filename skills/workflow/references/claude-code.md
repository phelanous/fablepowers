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
| Dispatch several seats at once (independent plan tasks) | Several Agent calls in one assistant message, each with the seat's `subagent_type` and a prompt naming its task worktree, without `isolation`. See [Parallel dispatch](#parallel-dispatch); verified in a full plan run by live eval 6 (T7-fix1 report, round 2). |
| Task worktree (create / remove) | `git worktree add -b fp/<plan-key>/t<id> <plan worktree>/.worktrees/<plan-key>-t<id> <plan-branch>`, later `git worktree remove` and `git branch -d`; not EnterWorktree. Verified under the session directory in T0 §3 and §8; see [Parallel dispatch](#parallel-dispatch). |
| Wait on a run longer than one tool call | A script file that writes an exit-status `.done` marker, started with Bash `run_in_background`, waited on in bounded calls (verified in T7's eval 9, T7 report F2). See [Parallel dispatch](#parallel-dispatch). |

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
- While any design is pending: Write, Edit, MultiEdit or NotebookEdit on any Claude Code settings file, `.claude/settings.json` or `.claude/settings.local.json`, wherever it is (the repo, `~/.claude`, any other directory). The path's last two components are matched on the path as given and after resolving symlinks, compared like marker names (case-insensitively and as NTFS resolves them). The reason names the pending design and says the user can make the settings change themselves, or approve or withdraw first. This closes the usual settings files to the edit tools; it does not stop an edit-tool write to the installed plugin's own hook files (`hooks/approval_gate.py`, `hooks/hooks.json`), to a config directory not named `.claude` (`$CLAUDE_CONFIG_DIR`), or to managed settings. Those are in the accepted gap below.
- Always: Write, Edit, MultiEdit or NotebookEdit on a path with a component named `pending` or `approved` under a `.fablepowers` component. Names compare case-insensitively and as NTFS resolves them (trailing dots and spaces, and `:stream` suffixes, are ignored).

**Approving.** Two user actions, and only these, write `approved`:

- `/fablepowers:approve [key or spec path]`, recorded on the `UserPromptExpansion` event. One pending design needs no argument; with several, a missing or unknown argument blocks the command and lists the keys, and nothing is recorded. The approve and withdraw skills set `disable-model-invocation: true`, which makes Claude Code refuse the model's own Skill call before any hook runs. That setting is what keeps the model from approving itself, and a test asserts it.
- Answering **Approve** to the design question (AskUserQuestion), recorded on PostToolUse from `tool_response.answers`. It counts only when the question's options are exactly Approve and Changes needed and exactly one design is pending with its spec file present. Otherwise the hook tells the model and the user why it recorded nothing, and which command to run. Changes needed records nothing; the design stays pending.

**Withdrawing.** `/fablepowers:withdraw [key or spec path]` removes `pending` for an abandoned design (same argument rules). The spec file stays.

**Escape hatch.** `FABLEPOWERS_GATE=off` in the environment: nothing is denied, and each would-be denial is appended to `.fablepowers/gate.log`. Malformed payloads and internal errors also allow and are logged there.

**Python.** The gate needs Python 3.8+ (stdlib only, run with `-I`). The launcher uses `$FABLEPOWERS_PYTHON` when set (then it is the only candidate), else `python3` on PATH, then `/usr/bin/python3`, `/usr/local/bin/python3`, `/opt/homebrew/bin/python3`. With no usable python the gate is disabled and allows everything, and shows the warning `fablepowers approval gate disabled: python3 not found` once per session (marker `${TMPDIR:-/tmp}/fablepowers-gate-warned-<uid>-<session_id>`). In a repository whose `.fablepowers/` exists it warns on any hooked call. In any other repository, including a fresh clone or a linked worktree where `.fablepowers/` does not exist yet, it warns only on the calls where the gate would have acted: a PostToolUse Write creating a `.md` under `docs/specs/`, an AskUserQuestion call, and the UserPromptExpansion of `fablepowers:approve` or `fablepowers:withdraw`. The launcher classifies these with bash pattern matches on the raw payload. Other calls, and everything outside git, stay silent.

**Accepted gap: shell writes.** The gate watches the edit tools and the dispatch, not shell commands. Through a shell command the model could forge or delete markers (including creating a directory named like one), write a spec without pending it, or write a hook into a settings file. Such a hook could auto-answer the approval question: Claude Code lets a PreToolUse hook fill in AskUserQuestion's answers, and the result is indistinguishable from a user's. While a design is pending, its edit tools are blocked from repo code and from the usual Claude Code settings files in any location; its shell is not. Nor are its edit tools blocked from the installed plugin's hook files (one Edit to `approval_gate.py` could disable the gate, taking effect on the next hooked call; an Edit to `hooks.json` could disable it or add an auto-answer hook, though hook configuration is loaded at session start, so that likely needs a new session), from a config directory not named `.claude`, or from managed settings; those paths are outside the project, so only Claude Code's own permission prompt stands in the way. All of these are adversarial, outside the user's threat model: the gate stops a session rolling past approval; it is not a sandbox.

## Parallel dispatch

`fablepowers:subagent-execution` runs a plan's independent tasks at the same time, each in its own task worktree. On Claude Code that resolves as below. Every fact carries a label:

- **verified (T0 §n)**: established in the 0.8.0 spike, live `claude -p` runs on Claude Code 2.1.306 with transcript and hook-log evidence. The excerpt for section n is in `docs/rationale.md`, "Evidence for the Claude Code reference".
- **verified (T7 report Fn)**, and **T7-fix1 report**: found in the 0.8.0 live evals (`tests/evals/`), on the same CLI version. The excerpts are in the same section of `docs/rationale.md`.
- **unverified**: not checked in a run.

**Status.** Parallel dispatch in a full plan run is **verified**: live eval 6 (`tests/evals/`: two independent tasks and one dependent) passed 9 of 9 assertions in `claude -p`, with the two independent tasks dispatched in one message to their own task worktrees, overlapping active intervals, `--no-ff` merges each followed by a check, and cleanup (T7-fix1 report, round 2). The mechanisms underneath it were verified in T0, as listed here. Merge-conflict handoff (eval 7: `git merge --abort`, then a merge-fix implementer) passed 1 of its first 6 live runs, because orchestrators usually foresaw the clash at spot-check and fixed it first; with a fixture whose task diffs are each correct, it passed 2 of 2. After the integration-review fixes, eval 6 passed again (wave-1 concurrency 1.88), and eval 8 passed with its `Touches: none` control task overlapping a serialized task and running the pre-commit suite, not the e2e. Evals 9, 10 and the resume case last ran before those fixes.

**Dispatch.**

- Several Agent calls in one assistant message, each with the seat's `subagent_type` and a prompt naming its task worktree by absolute path.
- No `isolation` parameter. The task worktree is the one the orchestrator created, not the Agent tool's own `.claude/worktrees/agent-<id>`.
- Two foreground Agent calls in one message ran with overlapping active intervals. The parent resumed only after both had returned, and both finished before `-p` exited (verified, T0 §1).
- Their `.meta.json` recorded `requestShape: "foreground"` and `requestNonInteractive: true`. No `run_in_background` was passed (verified, T0 §7).
- Background Agent calls (an async launch, then a completion notification) are also acceptable for a wave: an orchestrator chose them in T7's eval6-resume run, and its T1 and T3 ran with overlapping active intervals (verified, T7 report F3).

**Where task worktrees live.** Under the plan worktree: `<plan worktree>/.worktrees/<plan-key>-t<id>`, not under the main checkout.

- The desktop app's write guard refuses edits under the main checkout from a session in a `.claude/worktrees/` worktree. That was verified while executing the 0.8.0 plan itself, not in T0 (plan binding resolution 5).
- A subagent's `cd` into a directory outside the session's working directories (its launch directory and any `--add-dir`) is blocked and listed in `permission_denials` (verified, T0 §3). A task worktree inside the plan worktree is under the launch directory when the session runs in the plan worktree.
- `.worktrees/` is kept out of `git status` by a self-ignoring `<plan worktree>/.worktrees/.gitignore` holding `*`, written with the Write tool. Not `info/exclude`: in `-p`, Claude Code 2.1.306 refuses every write under `.git/` as a sensitive file, by Bash or by Edit, and an `Edit(.git/info/exclude)` allow rule doesn't lift it (verified, T7 report F1). Whether an interactive session prompts instead is unverified.

**Working directory in a subagent.** `cd` does not persist between Bash calls: the next call starts in the session's launch directory again (verified, T0 §3). So the dispatch tells the implementer to:

- run git as `git -C <task worktree> …`, and prefix every other Bash command with `cd <task worktree> &&`. A `cd` and its command in one call work (verified, T0 §3). But `cd <task worktree> && git …` was refused in `-p` ("Permission to use Bash has been denied"), and the refusal did not appear in `result.permission_denials`. The same implementer's `git -C` calls ran (verified, T7-fix1 report, eval 6);
- use absolute paths for Read, Edit and Write. Edit and Write with absolute paths in a task worktree worked (verified, T0 §3). In that run Write and Edit were allowed through `--allowedTools`. Whether acceptEdits alone admits them outside the session's directories is unverified.

**Hook `cwd`.** In a subagent's hook payload, `cwd` is always the session's launch directory. That holds right after a `cd`, and for a Write or Edit inside a task worktree (verified, T0 §2).

- A hook that needs the task worktree has to read it from the `tool_input` paths or `git -C` arguments.
- The payload's `transcript_path` is the parent's transcript. `agent_id` and `agent_type` are present for subagents only (verified, T0 §2).
- For the approval gate, a subagent's marker toplevel is therefore the plan worktree, where the workspace lives. That is inferred from the gate's toplevel rule above, unverified.

**Waiting on long runs.** The marker pattern from `fablepowers:behavioral-testing`, in the shape Claude Code admits:

- Write the run into a script file in scratch space that runs the command with output to a log, then writes `exit <status>` to the `.done` marker.
- Start `bash <script>` with Bash `run_in_background`.
- Wait on the marker, or on the completion notification, in bounded calls, each under the Bash tool's timeout, for example `timeout 540 bash -c 'until [ -f <out>.done ]; do sleep 5; done'`. The 600,000 ms maximum is the Bash tool's documented limit (unverified in T0).
- Never `pgrep -f`.

Why the script file (verified in `-p` on Claude Code 2.1.306, T7 report F2): under pattern allow rules, a Bash command with a `( … )` group or a variable such as `$?` is denied ("can't be checked before it runs"), so the one-line `( cmd; echo "exit $?" > <out>.done ) > <out> &` never runs. With sandbox auto-allow it is admitted, but the `&` job is killed when the call's shell exits. The script-plus-`run_in_background` shape ran without a denial in eval 9, for an implementer and for the orchestrator's post-merge check.

A Bash `run_in_background` completion notification does reach a running subagent: the one that started the job, not the parent (verified, T0 §4). But it arrives only at that subagent's next tool-result boundary. In T0 it was queued while a 40 s foreground call ran, and delivered when that call returned (verified, T0 §4). It carries the task summary and the output-file path, not the command's stdout (verified, T0 §4). So the notification is a completion signal, not the result: it lands after whatever call the agent is already in, and the agent still reads the marker and the log.

**Headless runs.** Under `-p` with acceptEdits, these `--allowedTools` patterns admitted the commands without a prompt (verified, T0 §8):

- `Bash(git worktree:*)`, `Bash(git merge:*)` and `Bash(git branch:*)` admitted the orchestrator's `git worktree add`, `git worktree remove`, `git merge --no-ff` and `git branch -d`.
- `Bash(git -C:*)` admitted the subagents' `git -C <wt> add` and `commit`.
- The session's patterns apply to subagents too. In `-p` a command no pattern admits is denied and listed in `permission_denials`, not prompted.
- `git merge --abort` was not run in T0. That `Bash(git merge:*)` admits it is unverified.

## Report-name write guard

Claude Code refuses a subagent's write to a file whose basename is a generic report name — `report.md`, `summary.md`, `findings.md`, `analysis.md` — in any directory and any case. That is why every dispatch names a workspace path such as `reports/task-<n>.md`, and why each agent body says to return the full report inline (and not to write it through a shell command instead) when its write is refused.

## Session logs

Transcripts are JSONL files under `~/.claude/projects/<cwd>/`, where `<cwd>` is the session's working directory with every `/` and `.` replaced by `-`. The main session is `<session-id>.jsonl`; subagents dispatched from it are `<session-id>/subagents/agent-<id>.jsonl` (with a `.meta.json` beside each). Agents run with worktree isolation start with `cwd` under `<repo>/.claude/worktrees/agent-<id>`.

For parallel dispatch, the links between parent and subagents are these (verified, T0 §5 and §6; see [Parallel dispatch](#parallel-dispatch)):

- Agent calls from one assistant message share the parent's API message id.
- Each subagent's `.meta.json` holds `agentType`, `description`, `toolUseId` (the parent's Agent `tool_use.id`) and `requestShape`.
- The parent's tool_result carries `toolUseResult.agentId`, which matches `agent-<agentId>.jsonl` and the `agentId` on every subagent line.
- Subagent lines carry `isSidechain: true`, and their `cwd` is the session's launch directory.

## Other harnesses

- **Codex (0.5.0):** supported; see `codex.md` beside this file (seats Sol / Terra / Sol by default, overridable per user in `models.toml`).
- **OpenCode (0.6.0):** supported; see `opencode.md` beside this file (seats pinned per user in `models.toml` `[opencode]`, else the session model).
- **Pi (0.7.0):** supported; see `pi.md` beside this file (seats dispatched with `fablepowers_dispatch`, pinned per user in `models.toml` `[pi]`, else the session model).
