# Codex harness reference

The fablepowers skills and agent bodies name actions ("dispatch the implementer seat", "ask the user a two-option question", "track tasks"). On OpenAI Codex those actions resolve to the tools, models and mechanisms below. Tested with Codex CLI 0.162.1. The Claude Code mapping is the sibling file `claude-code.md`; where this file says "as on Claude Code", the details are there.

The session-start hook injects the workflow map, the plugin root and the **seat table** (each seat's model and reasoning effort, from defaults and the user's `models.toml`). Read this file before invoking another fablepowers skill, dispatching a seat or asking for design approval.

## Actions → tools

| Action the skills name | Codex |
|---|---|
| Invoke a skill | Read `<plugin-root>/skills/<skill>/SKILL.md` and follow it. Codex lists the skills as `fablepowers:<skill>`; the user can load one with `$fablepowers:<skill>`. |
| Dispatch a seat (implementer, strict implementer, reviewer) | The spawn tool of your session's multi-agent generation, with the seat's model and effort from the seat table and the message convention below. |
| "Never a generic agent that inherits your model" | Never spawn without `model` and `reasoning_effort`, never with a model you picked yourself, and never with a forked context (`fork_turns:"none"` on v2; no `fork_context` on v1). |
| Ask the user a structured question (the two-option design approval, bundled cosmetic choices) | Plain text: the question and its options in your message, then **end your turn**. Codex has no blocking question outside Plan mode, and Plan mode does not stop edits, so it is no substitute. For design approval, see [Asking for approval](#asking-for-approval). |
| Track tasks | The plan file and the ledger `.fablepowers/<plan>/progress.md`; Codex's own plan tool, where your session has one, is optional. |
| Native worktree tool (create / exit) | None. Use `git worktree add` as `fablepowers:using-git-worktrees` describes; the rules file below lets it run in the sandbox. |
| Plugin root (where `skills/`, `agents/`, `hooks/` live) | The absolute path the session-start preamble names. Hook commands get it as `PLUGIN_ROOT` (and `CLAUDE_PLUGIN_ROOT`). The installed copy lives under `~/.codex/plugins/cache/<marketplace>/fablepowers/<version>/` and is the live root: editing the repo needs a reinstall. |

## Seats → models

The seat table in the injected context is authoritative: spawn each seat with exactly its `model` and `reasoning_effort`.

| Seat | Tier | Role prompt | Default model | Default effort |
|---|---|---|---|---|
| Implementer | frontier | `agents/implementer.md` | `gpt-6.1-sol` | high |
| Strict implementer | mid | `agents/strict-implementer.md` | `gpt-5.6-terra` | medium |
| Reviewer | frontier | `agents/reviewer.md` | `gpt-6.1-sol` | high |

The defaults require Sol access. `gpt-6.1-sol` is taken from the Codex 0.162.1 binary's embedded model catalog (which also lists `gpt-6-sol` and `gpt-5.6-sol`); it was not confirmed against an account with Sol, so verify it with your account (`codex debug models`). `gpt-5.6-terra` is confirmed in an account catalog.

**`models.toml`.** `${XDG_CONFIG_HOME:-~/.config}/fablepowers/models.toml`, read at session start (a change applies from the next session). Only the `[codex]` table is read; a `[claude-code]` table is not applied in 0.5.0 (Claude Code keeps its frontmatter pins).

```toml
[codex]
implementer = "gpt-6-luna"
implementer_effort = "medium"
strict_implementer = "gpt-5.6-terra"
strict_implementer_effort = "medium"
reviewer = "gpt-6-luna"
reviewer_effort = "high"
```

- Keys: `implementer`, `strict_implementer`, `reviewer` and `<seat>_effort`. Values are double-quoted strings; `#` comments (full-line or trailing) are fine; CRLF and a UTF-8 BOM are tolerated.
- A model id matches `[A-Za-z0-9._:/-]{1,64}`. An effort is one of `low`, `medium`, `high`, `xhigh`, `max`, `ultra` (which efforts a model accepts depends on the model).
- Anything else (unknown key, single quotes, unquoted value, bad id or effort, a malformed line, a duplicate key, where the last one wins) falls back to that key's default and adds a warning line under the seat table, at most three plus a count. A missing or empty file means the defaults, silently; an unreadable one gives the defaults and a warning.

**Unavailable model.** If a seat spawn fails because the model is unknown or the account has no access to it, stop. Tell the user which seat and model failed and that they set the seat in `models.toml` (path above), then start a new session. Never retry the spawn without the `model` argument or with a model you chose: the child would silently run on an inherited model, the defect the seats exist to prevent.

## Dispatch convention

Codex picks the multi-agent tool generation per model; your tool list shows which one you have.

- **v2** (e.g. `gpt-6-luna`, `gpt-5.6-terra`): the collaboration namespace's spawn tool (hooks see it as `collaborationspawn_agent`), with
  `task_name: "fablepowers_<seat>_<suffix>"`, `fork_turns: "none"`, `model`, `reasoning_effort`, `message`.
  `<seat>` is `implementer`, `strict_implementer` or `reviewer`. A task name may hold only lowercase letters, digits and underscores, and must be unique in the session: make the suffix the task and attempt, e.g. `fablepowers_implementer_t3`, `fablepowers_reviewer_t3_r2`.
- **v1** (e.g. `gpt-5.6-luna`): `spawn_agent` with `message`, `model`, `reasoning_effort`; no `fork_context`, no `task_name`.

The message, in both generations:

```
fablepowers-seat: <implementer | strict-implementer | reviewer>
Read <plugin-root>/agents/<seat>.md and follow its body as your role prompt; its frontmatter is Claude Code's and does not apply.
<the dispatch the skill describes: plan path and task heading, spec path, how to run the tests, commit convention, report path>
```

The first line is how the approval gate recognises a v1 reviewer (v2 reviewers by the `fablepowers_reviewer` task-name prefix); keep it first and exact. Wait for results with the same generation's wait tool. Do not give an agent another seat's work through follow-up or send-message tools.

**No sub-spawns.** Codex's default agent depth (`agents.max_depth = 1`) gives children no spawn tool, the equivalent of Claude Code's `disallowedTools: Agent`. Do not raise it.

**Reports.** Codex has no report-name write guard, but dispatches still name a workspace path such as `.fablepowers/<plan>/reports/task-<n>.md`, as on Claude Code.

## Bootstrap

`hooks/hooks.json` registers the same SessionStart hook as on Claude Code (matcher `startup|clear|compact`). The hook tells Codex from Claude Code by the payload's `transcript_path`: Codex's is a `rollout-*.jsonl` under `~/.codex/sessions/` (or `$CODEX_HOME/sessions/`), Claude Code's a `<uuid>.jsonl` under `~/.claude/projects/`. Failing that, `PLUGIN_ROOT` set and equal to `CLAUDE_PLUGIN_ROOT` means Codex (Claude Code sets only `CLAUDE_PLUGIN_ROOT`). The `model` and `permission_mode` keys decide nothing: Codex's SessionStart carries both, but Claude Code's compact SessionStart carries `model` too, and its hook input can carry `permission_mode`. On Codex it injects a short preamble (harness, a pointer to this file, the plugin root), the seat table with any `models.toml` warnings, and the workflow map, at most 8,000 characters. A resumed session (`source: "resume"`) is not re-injected; its restored history already holds the earlier injection. The hooks run only once trusted (see [Hook trust](#hook-trust)).

## Approval mechanism

Same markers, states and rules as on Claude Code (`.fablepowers/<key>/pending` and `approved`, written only by the hook; see `claude-code.md`), enforced by the same `hooks/approval-gate` and `hooks/approval_gate.py`, which take a Codex branch for Codex's tool names and for a `UserPromptSubmit` with `turn_id`. Python 3.8+ is needed, as on Claude Code. Without it the gate allows everything and warns once per session; on Codex the warning also goes out as context on a PostToolUse `apply_patch` or a `UserPromptSubmit`, and neither a PreToolUse (whose `systemMessage` nobody sees) nor a subagent's event (with `agent_id`, whose context goes to the subagent) uses up the once-per-session warning.

**Pending.** A PostToolUse `apply_patch` from the main session (no `agent_id`) whose `*** Add File:` creates `docs/specs/<name>.md`, confirmed by the tool response's `A <path>` line, or whose `*** Update File:` with `*** Move to:` moves a file to `docs/specs/<name>.md`, confirmed by `M <destination>`. Patch paths are relative to the session's working directory, not the repository root: from a subdirectory, `docs/specs/x.md` lands in `<subdir>/docs/specs/` and is not gated, so give the path from where the session runs (e.g. `../docs/specs/x.md`). Unlike Claude Code, an `Add File` over an existing spec with no markers pends it again; an approved or pending key is left alone. Write the spec with `apply_patch`, never through the shell.

**What it blocks** (PreToolUse, `permissionDecision: "deny"`):

- While any design is pending: a spawn that is not a fablepowers reviewer (v2 `task_name` `fablepowers_reviewer` or `fablepowers_reviewer_*`; v1 message whose first line is `fablepowers-seat: reviewer`). Every other spawn is denied, unnamed ones included.
- While any design is pending: an `apply_patch` with any Add, Update, Delete or Move path inside the repository outside `docs/specs/`, `docs/plans/` and `.fablepowers/`. One such path denies the whole patch. Paths outside the repository stay allowed.
- While any design is pending: an `apply_patch` touching Codex configuration anywhere: `.codex/config.toml`, `.codex/rules/`, `.codex/agents/`, `.codex/hooks*`, and `$CODEX_HOME/config.toml`.
- Always: an `apply_patch` creating, changing, deleting or moving a marker, names compared as on Claude Code (case-insensitive, NTFS variants).
- Paths as Codex reads them: the patch is split into lines on `\n` only, as Codex splits it, and a header path is everything after `: ` to the end of the trimmed line, so `*** Add File:   x` names `  x`, not `x`.
- Fails closed: a patch the gate cannot parse, or a header path holding a control character (C0, DEL, C1, U+2028 or U+2029, which includes `\v`, `\f` and `\x1c`–`\x1e`) or one that cannot be resolved, is denied while a design is pending, and always when it could name a marker, judged by its text with and without the control characters and by where it resolves (a symlink into `.fablepowers/`).

Codex shows a deny reason to the model, which must relay it. A hook's `systemMessage` and a block reason never reach the model or a `codex exec` user, so everything the gate says goes in `additionalContext` or the deny reason.

**Approving.** Only the user's own message approves: `$fablepowers:approve [key]` as the whole message (the key is the spec's file name, with or without `.md`; one pending design needs none). The user types it, or completes it from the `$` menu in the CLI, which inserts the same text; in the Codex app they type it as text, since a skill picked from the app's menu reaches the hook as an empty prompt. Blanks around it and one trailing newline are ignored; trailing words, a second argument, text before it, the `/fablepowers:approve` form, a "yes" or "Approve" in chat: none of these approve. A message that starts with `$fablepowers:approve` or `$fablepowers:withdraw` but is not the command records nothing: a single trailing word is read as the key (an unknown key is answered below), and anything else gets context saying it was not recognised; ask the user to send the command on its own. Subagent prompts (with `agent_id`) never approve. With several designs pending and no key, or an unknown key, the hook records nothing and its context lists the keys; tell the user and ask them to resend with one. The answer arrives as context on the user's turn and is recorded with `via: "command"`.

**Withdrawing.** `$fablepowers:withdraw [key]`, same rules; the spec file stays.

The `approve` and `withdraw` skills carry `agents/openai.yaml` with `allow_implicit_invocation: false`, so they are not offered to you. Never write or remove the markers, and never send the command yourself.

**Escape hatch.** `FABLEPOWERS_GATE=off` in the environment, as on Claude Code. Every Codex deny ends with the recovery line: if an approval does not register, the hooks may be untrusted; trust them in `/hooks`, or set `FABLEPOWERS_GATE=off`.

### Asking for approval

There is no approval question on Codex. The approval turn is design-spec's brief, then a plain-text ask with the same two options, in this shape:

> Approve: reply `$fablepowers:approve` (type it, or pick it from the `$` menu). Changes needed: tell me what to change.

Then end your turn. A `codex exec` run ends there; the user continues it with `codex exec resume <session-id> '$fablepowers:approve'`.

### Differences from Claude Code

| | Claude Code | Codex |
|---|---|---|
| Spec create | Write tool create | `apply_patch` Add File, paths from the session cwd; re-adding an unmarked spec re-pends it |
| Approval | answer Approve to the question, or `/fablepowers:approve` | `$fablepowers:approve` as a message only |
| Dispatch gated | Agent `subagent_type` implementer / strict-implementer | every spawn except a named reviewer |
| Config guard | `.claude/settings*.json` | `.codex/config.toml`, `rules/`, `agents/`, `hooks*`, `$CODEX_HOME/config.toml` |
| Hook messages | `systemMessage` shown to the user | model-visible context only |
| Model can't approve because | `disable-model-invocation: true` | the hook reads only the user's literal prompt; `allow_implicit_invocation: false` hides the skills |

## Commits: the rules file

Under `workspace-write`, `.git` is read-only, so every `git add` and `git commit` asks for approval (and fails in `codex exec`). The opt-in rules file `codex/rules/fablepowers.rules` allows plain `git add`, `git commit` and `git worktree add`; `git -c … commit`, `git push` and every other git command keep Codex's normal approval. Copy it to the project's `.codex/rules/` (the project must be trusted) or to `~/.codex/rules/`; both locations were verified. Check it with `codex execpolicy check -r codex/rules/fablepowers.rules git commit -m x`. Commit with plain `git commit`, no `-c` options, so the rule matches.

## Hook trust

Codex runs a plugin's hooks only after the user trusts them in `/hooks`. Trust is kept per handler, keyed by position (`<plugin>@<marketplace>:hooks/hooks.json:<event>:<group>:<handler>`) with a hash of the handler's entry. An update that changes `hooks.json` needs trusting again: 0.5.0 appends three handlers (the two spawn tools and `UserPromptSubmit`), so a 0.4.0 install keeps its eight trusted handlers and the user trusts the three new ones. The hash covers the `hooks.json` entry, not the script it runs. Until they are trusted they do not run: no workflow map, no gate.

For headless runs, `scripts/codex-hook-trust.sh [plugin@marketplace] [cwd]` prints a one-run override; it reads `hooks/list` from `codex app-server` and never writes config. On any error (no `codex`, app-server failure, plugin not listed) it prints nothing on stdout, explains on stderr and exits 1, so check its status before running Codex; `codex -c "" exec` would run with the hooks untrusted:

```
trust="$(scripts/codex-hook-trust.sh fablepowers@fablepowers)" || exit 1
codex -c "$trust" exec …
```

The project must be trusted in `~/.codex/config.toml` too (`[projects."<path>"] trust_level = "trusted"`) for its `.codex/rules/` to apply. Codex writes that entry itself on the first trusted session there. A `-c projects."<path>".trust_level="trusted"` override works for a fresh `codex exec` but is not honoured for project rules on `codex exec resume`: a resumed run without the persisted entry gets no project rules, so `git commit` fails on the read-only `.git`.

## Accepted gaps

The gate stops a session rolling past approval; it is not a sandbox. Not covered:

- **Shell writes.** The gate watches `apply_patch` and the spawn tools, not shell commands: a shell command can forge or delete markers or write files. That includes `apply_patch` run as a shell heredoc, which Codex reports as a Bash call with no PostToolUse, so it bypasses the gate and never marks a spec pending.
- **A mislabelled spawn.** The task name and the seat line are conventions the model writes; a model naming an implementer `fablepowers_reviewer_*` passes.
- **Re-tasking an allowed agent** through follow-up or send-message tools while a design is pending.
- **Codex home and the plugin cache.** The config guard covers only the config paths listed above, not all of `~/.codex` (or `$CODEX_HOME`) or the installed plugin under `~/.codex/plugins/cache/`. An `apply_patch` to the gate's own scripts there is not blocked, and Codex's hook trust does not notice it (the hash covers `hooks.json` entries only). `$CODEX_HOME/rules`, `agents` and `hooks*` are guarded only when that directory is named `.codex`.
- **Custom `CODEX_HOME` guard parity.** A `CODEX_HOME` set to a directory not named `.codex` gets less protection than `~/.codex`. The guard covers only its `config.toml`, not its `rules/`, `agents/` or `hooks*`. That `config.toml` path is compared exactly (normalised and through symlinks), not case-insensitively or NTFS-normalised the way `.codex` path components, markers and OpenCode's config homes are.
- **App skill items.** An approve picked from the Codex app's skill menu is invisible to the hook; it must be typed as text.
- **Project trust.** Codex records `[projects."<path>"] trust_level = "trusted"` in `~/.codex/config.toml` on its own on the first trusted session in a project; the rules file in `.codex/rules/` relies on that entry (a `-c` trust override is not honoured for project rules on `exec resume`; see [Hook trust](#hook-trust)).

## Session logs

Rollouts are JSONL files under `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`. A subagent's rollout links to its parent through `session_meta.source.subagent.thread_spawn`; the model and effort a turn actually ran on are in its `turn_context` records. Output tokens come from `token_usage_record` (`thread_token_usage`, which equals the sum of its per-call `usage`). Do not use the last cumulative `token_count` total instead: after a compaction it under-reports (27 against 103 in one fixture rollout). On v2 the dispatch message is stored encrypted. `scripts/analyze_delegation.py --harness codex` (in the repo) reads these rollouts read-only, `--codex-home` to point elsewhere; `.jsonl.zst` rollouts and rollouts whose first line is not a `session_meta` are skipped with a note, and Codex records no cost, so its cost cells print `-`.
