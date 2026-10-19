# OpenCode harness reference

The fablepowers skills and agent bodies name actions ("dispatch the implementer seat", "ask the user a two-option question", "track tasks"). On OpenCode those actions resolve to the tools, agents and mechanisms below. Tested with OpenCode 2.0.29. The Claude Code mapping is the sibling file `claude-code.md`, the Codex one `codex.md`, the Pi one `pi.md`; where this file says "as on Claude Code", the details are there.

fablepowers runs on OpenCode as a plugin, `opencode/index.js`, loaded by OpenCode's server. The plugin is an adapter: every approval-gate decision and marker write happens in `hooks/approval_gate.py`, and the seat table is parsed by `hooks/session-start`, the same files Claude Code and Codex run. At the start of each root session the plugin injects the bootstrap: a short preamble, the **seat table** and the workflow map. Read this file before invoking another fablepowers skill, dispatching a seat or asking for design approval.

## Actions → tools

| Action the skills name | OpenCode |
|---|---|
| Invoke a skill | The `skill` tool with `fablepowers:<skill>`. The plugin registers every skill except approve and withdraw, which are user commands. A loaded skill shows its base directory ("Base directory for this skill: …"), so relative paths such as `../integration-review/review-package` resolve from it. |
| Dispatch a seat (implementer, strict implementer, reviewer) | The `subagent` tool with `agent: "fablepowers-implementer"`, `"fablepowers-strict-implementer"` or `"fablepowers-reviewer"`, plus `description` and `prompt` (the dispatch). Never pass `model`. |
| "Never a generic agent that inherits your model" | Never dispatch the built-in `general` agent (or any other agent) to do a seat's work. The built-in read-only `explore` agent is fine for codebase exploration. |
| Ask the user a structured question (the two-option design approval, bundled cosmetic choices) | The `question` tool: `{questions:[{question, header, options:[{label, description}]}]}`. It blocks until the user answers in the TUI (or app). In `opencode run` it is cancelled ("This non-interactive run cannot ask…"); then ask in plain text and end your turn. |
| Track tasks | The plan file and the ledger `.fablepowers/<plan>/progress.md`. OpenCode has no todo tool. |
| Native worktree tool (create / exit) | None. Use `git worktree add` as `fablepowers:using-git-worktrees` describes. |
| Plugin root (where `skills/`, `agents/`, `hooks/` live) | The absolute path the bootstrap preamble names. A git install lives in OpenCode's plugin cache (`~/.cache/opencode/npm/git-fablepowers-<hash>/…/node_modules/fablepowers/`) and is the live root. Editing your checkout changes nothing until it is reinstalled. A local-directory install is the directory itself. |

Tool names are OpenCode 2.x's own: `shell` (not bash), `write` / `edit` (`patch` instead of both on `gpt-*` models), `subagent`, `question`, `skill`, `read`.

## Seats → agents and models

The plugin registers one agent per seat, with `mode: "subagent"`. Its system prompt carries the seat's role prompt inline: the body of `<plugin-root>/agents/<seat>.md`, frontmatter stripped (that is Claude Code's), read once when the plugin starts, with the file path named for humans. If the role file can't be read, the system prompt points at the file instead and the plugin logs a warning to `.fablepowers/gate.log`. Each seat gets one added permission: `subagent` denied (no sub-spawns). The plugin grants no `external_directory` access: skills arrive through the skill tool, which needs none, and OpenCode can't scope that permission to reads only. A seat that reads another file under the plugin root (a skill's `references/`, or the role file in the fallback case) follows your own `external_directory` rules. OpenCode's defaults allow it; an `ask` rule makes the seat ask.

| Seat | Tier | Agent | Role prompt | Model |
|---|---|---|---|---|
| Implementer | frontier | `fablepowers-implementer` | `agents/implementer.md` | `[opencode] implementer`, else the session model |
| Strict implementer | mid | `fablepowers-strict-implementer` | `agents/strict-implementer.md` | `[opencode] strict_implementer`, else the session model |
| Reviewer | frontier | `fablepowers-reviewer` | `agents/reviewer.md` | `[opencode] reviewer`, else the session model |

The seat table in the bootstrap is authoritative. It names each seat's model, or says "session model (unpinned)".

**`models.toml`.** `${XDG_CONFIG_HOME:-~/.config}/fablepowers/models.toml`. On OpenCode only the `[opencode]` table is read, and `[codex]` is ignored (Codex likewise ignores `[opencode]`).

```toml
[opencode]
implementer = "opencode/big-pickle#high"
strict_implementer = "opencode/mimo-v2.6-flash-free"
reviewer = "openrouter/anthropic/claude-x.1"
```

- Keys: `implementer`, `strict_implementer`, `reviewer`. A value is `provider/model`, optionally followed by `#variant`. The provider is the part before the first `/`; the model id is the rest and may itself contain `/`. The variant goes to the agent's `model.variant`.
- An id has at most 128 characters from `A-Z a-z 0-9 . _ : - /` plus one `#`. It needs a non-empty provider, non-empty path segments, and a non-empty variant after `#`. Values are double-quoted. `#` comments (full-line or trailing) are fine, and CRLF and a UTF-8 BOM are tolerated. A duplicate key: the last one wins, with a warning.
- There are no `*_effort` keys on OpenCode: use a `#variant`. An effort key warns and is ignored.
- An unset or invalid seat runs on the **session's model**. The bootstrap then lists the unpinned seats in one warning line, and the parser warnings (an invalid id, an unknown key, a malformed line) above it. A missing file means every seat runs on the session model.
- **Seats are read when the server loads the plugin** for a directory (OpenCode keeps one plugin instance per directory). That is when the agents register, and the table stays cached until the server restarts. After editing `models.toml`, restart OpenCode, including its background service (`opencode serve --service`) if one is running. A new session alone does not pick up the change.

**Pinned means pinned.** When a seat has a model, the plugin deletes any `model` argument from a `subagent` call to that seat before it runs. An orchestrator cannot override the pin per dispatch. An unpinned seat passes `model` through, but don't send one: the seat table says the seat runs on the session model.

## Dispatch convention

```
subagent {
  agent: "fablepowers-<implementer | strict-implementer | reviewer>",
  description: "<task n — short>",
  prompt: "<the dispatch the skill describes: plan path and task heading, spec path, how to run the tests, commit convention, report path>"
}
```

The seat's system prompt already carries its role prompt. The prompt carries the dispatch only.

- **No sub-spawns.** Seats have `subagent` denied, and OpenCode's default subagent depth gives children no `subagent` or `question` tool.
- **Continuing a child.** `subagent` with an existing child's `sessionID` continues that child as the `agent` you pass: OpenCode switches the child to that agent (and to its model, when the agent has one). Continue a child only as its own seat. Never hand an implementer's session to the reviewer, or the reverse.
- **Reports.** Dispatches name a workspace path such as `.fablepowers/<plan>/reports/task-<n>.md`, as on Claude Code.

## Bootstrap

The plugin's `context` hook prepends the bootstrap to the first user message of each **root** session, inside `<fablepowers-bootstrap>…</fablepowers-bootstrap>`. It is applied on every model step and never doubled: the plugin skips a step only when its own bootstrap already leads the first user message, so a message that merely mentions the tag (your reasoning or reply, a quoted file) does not suppress it. Child sessions are skipped. After compaction it is added back. The bootstrap comes from `hooks/session-start --opencode`, run once when the plugin loads (3 s timeout). It holds:

- a preamble naming OpenCode, this file and the plugin root;
- the seat table and its warnings;
- the workflow map;

at most 8,000 characters in all.

The bootstrap degrades visibly:

- **No usable `python3`:** the first line reads `fablepowers approval gate disabled: python3 not found …`. The gate allows everything, and `/fablepowers:approve` answers that it recorded nothing.
- **No bash, or session-start failed or timed out:** a `fablepowers bootstrap unavailable: …` line plus the workflow map, read by the plugin directly. There is no seat table, so every seat runs on the session model. The gate still runs if python exists.

## Approval mechanism

Same markers, states and rules as on Claude Code (`.fablepowers/<key>/pending` and `approved`, written only by the gate). The plugin turns OpenCode's events into `harness: "opencode"` payloads for `hooks/approval_gate.py` (2 s timeout per call). The plugin itself only ever *denies*: it never sets an allow, so your own OpenCode permission rules keep working. Python 3.8+ is needed, as on Claude Code.

**Paths.** OpenCode reports edit paths relative to the **session directory**, the directory the session was started in, which may be a subdirectory of the repo. The gate resolves them against the session directory, then judges them against the git toplevel. A spec written from a session started in `sub/` lands in `sub/docs/specs/`. That file is not a design, so it is not gated, and while another design is pending it is outside the allowlist and denied. Start OpenCode from the repository root.

**Pending.** A root session's `write` that creates `docs/specs/<name>.md` (the tool reports `existed: false`) marks the design pending. So does an `edit` whose file status is `added`, or a `patch` `Add File` whose target the plugin found missing just before the call, or a `patch` `Update File` with `*** Move to: docs/specs/<name>.md` (as on Codex). Patch paths are matched as written and by real path, so a session started through a symlinked checkout counts too. Overwrites, and writes from a child session, don't. The pending notice is appended to the tool result the model sees. Create the spec with `write` (or `patch`), never through the shell.

**What it blocks** (`permission.evaluate`, `effect = "deny"`, plus a second check in `tool.execute.before` for `subagent`). The deny reason reaches the model as the tool's error:

- While any design is pending: a `subagent` dispatch to any agent except `fablepowers-reviewer` and `explore`, judged by the agent that will run, continuations included. Agent ids are real identities on OpenCode, so this rule cannot be satisfied by a label.
- While any design is pending: an edit (`write`, `edit`, `patch`) to a repository path outside `docs/specs/`, `docs/plans/` and `.fablepowers/`. One bad path denies the whole call. So does an edit with no usable path, or a path that cannot be resolved. Paths outside the repository stay allowed, except the two below.
- While any design is pending: OpenCode config. That is `opencode.json` or `opencode.jsonc` anywhere, anything under a `.opencode/` directory, `$XDG_CONFIG_HOME/opencode/` and `~/.config/opencode/`, and `fablepowers/models.toml` under either config home.
- While any design is pending: anything under the plugin root, except the allowlist above when the plugin root is the repository you are working in.
- Always: an edit to a marker, with names compared as on Claude Code (case-insensitive, NTFS variants). Config-home, `models.toml` and plugin-root paths are compared the same way.

**Approving.** Only the user approves, in one of three ways, and only from the **main (root) session**:

1. **Answer Approve** to design-spec's question in the TUI or app. The gate records it from the `question` tool's result only when the call holds exactly one question, the options are exactly **Approve** and **Changes needed**, the answer is exactly `Approve`, and exactly one design is pending. A free-text answer reading exactly `Approve` counts the same, since it is the user's own answer.
2. **Type `/fablepowers:approve [key]`** in the TUI or app (the key is the spec's file name, with or without `.md`; one pending design needs none). This runs the plugin's command, not a model turn. The gate's answer is posted to the session as a message, which starts a turn. When the gate gives no answer (timeout, error), the message says the command was not recorded and why; a command without a session id fails with that text instead.
3. **In `opencode run`**, which does not route slash commands: send the command as the whole message of the root session, `opencode run -s <session-id> /fablepowers:approve [key]`. Pass it as separate arguments, or quoted: `opencode run` wraps an argument holding a space in quotes, and the plugin strips one wrapping pair. Blanks around it and one trailing newline are fine. Trailing words, text before it, or "yes" are not the command. A message that starts like the command but isn't gets a "not recognised" answer and records nothing. The gate's answer is appended to the message, so the model relays it.

With several designs pending and no key, or an unknown key, nothing is recorded and the answer lists the keys. An approval's answer names the next step (`fablepowers:implementation-plan`). The model has no command tool, so it cannot run the command.

**The known-root rule.** Approve and withdraw (question, command or prompt) record only for a session the plugin has positively identified as root: the session lookup succeeded, and the session has no parent. A subagent session, or one whose lookup failed, gets "recorded nothing … main session" instead. Pending creation leans the other way: a write from a session whose lookup failed is treated as root, so a design is never missed.

**Withdrawing.** `/fablepowers:withdraw [key]`, by the same paths and rules. The spec file stays.

**Escape hatch.** `FABLEPOWERS_GATE=off` turns denies into `.fablepowers/gate.log` lines. Set it in the **OpenCode server's** environment (the background service's, for TUI sessions), not just your shell. The plugin also logs its own failures there (`opencode plugin: …`). Every hook fails open on an internal error, because OpenCode itself fails a tool or turn when a plugin hook throws. The only blocking outcomes are the gate's explicit denies.

### Asking for approval

As on Claude Code: design-spec's brief, then the `question` tool with exactly one question and the two options **Approve** and **Changes needed**, in a separate call. Close the brief with: answer **Approve**, or run `/fablepowers:approve`. In `opencode run` the question is cancelled. Ask in plain text and end your turn; the user continues with `opencode run -s <session-id> /fablepowers:approve`.

### Differences from Claude Code

| | Claude Code | OpenCode |
|---|---|---|
| Spec create | Write tool create | `write` (`existed: false`), `edit` (`added`), `patch` add; paths from the session directory |
| Approval | answer Approve, or `/fablepowers:approve` | the same, plus the command as a root-session message in `opencode run` |
| Dispatch gated | Agent `subagent_type` implementer / strict-implementer | every `subagent` except `fablepowers-reviewer` and `explore` |
| Config guard | `.claude/settings*.json` | `opencode.json(c)`, `.opencode/`, the config homes' `opencode/` and `fablepowers/models.toml`, the plugin root |
| Model can't approve because | `disable-model-invocation: true` | commands are user-only; the prompt path counts only the root session's message |

## Requirements

- **Python 3.8+** for the gate. The plugin searches the way the Claude Code launcher does: `FABLEPOWERS_PYTHON` as the only candidate when set; otherwise `python3` on PATH, then `/usr/bin/python3`, `/usr/local/bin/python3`, `/opt/homebrew/bin/python3`.
- **bash** for the bootstrap's seat table: `FABLEPOWERS_BASH`, then PATH, then `/bin/bash`, `/usr/bin/bash`, `/usr/local/bin/bash`, `/opt/homebrew/bin/bash`.
- The plugin sees the **server's** environment. OpenCode's background service inherits the environment of whatever first started it, so a python or bash found only through your interactive shell's PATH may be missing there. Set `FABLEPOWERS_PYTHON` / `FABLEPOWERS_BASH` in that environment, or rely on the absolute fallbacks.
- Node.js is not needed at runtime: OpenCode runs the plugin under its own runtime. The plugin's tests use `node --test`.

## Testing without the background service

Plain `opencode` commands talk to the background service, which loads the *installed* plugin. To test a checkout, use `opencode run --standalone …`, which starts a private server for that run. A scratch `XDG_CONFIG_HOME` holding an `opencode/opencode.json` with `{"plugins": ["/abs/path/to/fablepowers"]}` and a `fablepowers/models.toml` keeps your own config untouched; provider auth lives in the data directory and still works. A local-directory install loads the repo's root `index.js`, which re-exports `opencode/index.js`. A private `opencode serve` on `127.0.0.1` (stopped afterwards) covers the question form and the command API (`POST /api/session/:id/command`).

## Accepted gaps

The gate stops a session rolling past approval. It is not a sandbox. Not covered:

- **Shell writes.** The `shell` tool is not gated. A shell command can write files, forge or delete markers, or write a spec that is then never marked pending.
- **Self-approval through the shell or the API.** A model that runs `opencode run -s <root-session-id> /fablepowers:approve` through `shell`, or calls the server's API (`session.command`, a reply to the question form), produces exactly what the user's own approval looks like.
- **The plugin outside pending.** Edits under the plugin root are denied only while a design is pending. At other times an edit to the installed plugin (in the cache, or a local-directory install) is not blocked, and it could disable the gate before the next design.
- **Other config locations.** The config guard covers only the paths listed above. OpenCode config reached some other way (another config directory, an environment override) is not guarded.
- **Another plugin's permission hook** that runs after this one can set `effect = "allow"` over the gate's deny.
- **Custom `CODEX_HOME` guard parity** (Codex, recorded here for the cross-harness picture). The Codex gate compares a custom `$CODEX_HOME/config.toml` exactly, and guards that directory's `rules/`, `agents/` and `hooks*` only when it is named `.codex`. OpenCode's config homes, by contrast, are compared case-insensitively and NTFS-normalised. See `codex.md`.

## Session logs

Sessions live in SQLite at `~/.local/share/opencode/opencode.db`. In table `session_v2`, each row has `id`, `parent_id`, `agent`, `model` (JSON, including `variant`), cost and tokens: the model a seat actually ran on is there. Table `session_message` holds each message with its model, tokens (`output`, `reasoning`), recorded cost and tool calls; it is the token and cost source for the analysis, since the `session_v2` totals can disagree with it. `opencode session export <id>` prints one session. The server log is `~/.local/share/opencode/log/opencode.log`. The gate's own log is `<repo>/.fablepowers/gate.log`. `scripts/analyze_delegation.py --harness opencode` (in the repo) opens the db read-only (`mode=ro`, safe while the server runs), `--opencode-db` to point elsewhere; its output figure is `output + reasoning`.
