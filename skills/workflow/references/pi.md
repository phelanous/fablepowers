# Pi harness reference

The fablepowers skills and agent bodies name actions ("dispatch the implementer seat", "ask the user a two-option question", "track tasks"). On Pi those actions resolve to the tools, skills and mechanisms below. Tested with Pi 1.2.0 (`@earendil-works/pi-coding-agent`). The Claude Code mapping is the sibling file `claude-code.md`; Codex and OpenCode have `codex.md` and `opencode.md`. Where this file says "as on Claude Code", the details are there.

fablepowers runs on Pi as one extension, `pi/fablepowers.ts`, plus ten wrapper skills under `pi/skills/`. The extension is an adapter: every approval-gate decision and marker write happens in `hooks/approval_gate.py`, and the seat table is parsed by `hooks/session-start`, the same files the other harnesses run. In each root session the extension adds the bootstrap to the system prompt: a short preamble, the **seat table** and the workflow map. Read this file before invoking another fablepowers skill, dispatching a seat or asking for design approval.

## Install

```
pi install git:github.com/phelanous/fablepowers
```

Pi reads only the `pi` field of the root `package.json`: `{"extensions": ["./pi/fablepowers.ts"], "skills": ["./pi/skills"]}`. A git install is a full clone under Pi's agent directory (`~/.pi/agent/git/github.com/phelanous/fablepowers`); `pi install … -l` installs into the project's `.pi/` instead. To try a checkout without installing, run `pi -e /abs/path/to/fablepowers`.

The extension loads once per Pi session. A second copy in the same process (a `-e` checkout plus the installed package) registers nothing and logs one line to `.fablepowers/gate.log`; the copy Pi loads first wins, and `-e` packages load before installed ones. After `/new`, `/resume`, `/fork`, `/reload` or an RPC session switch, Pi re-runs the extension and it registers again.

## Actions → tools

| Action the skills name | Pi |
|---|---|
| Invoke a skill | The Pi skill `fablepowers-<skill>`: a skill written `fablepowers:<x>` is `fablepowers-<x>` on Pi. Pi lists skills in the system prompt and the model loads one with `read`; a user forces one with `/skill:fablepowers-<x>`. Each wrapper says to read `<plugin-root>/skills/<x>/SKILL.md` and follow it, with relative paths resolving against that file's directory. Approve and withdraw have no wrapper: they are user commands. |
| Dispatch a seat (implementer, strict implementer, reviewer) | The `fablepowers_dispatch` tool with `seat` (`implementer`, `strict_implementer` or `reviewer`), `task` (the dispatch) and an optional `cwd`. See [Dispatch](#dispatch). |
| "Never a generic agent that inherits your model" | Never do a seat's work through another dispatch tool (Pi's example `subagent` tool, a third-party package) or a `pi` started through `bash`. |
| Ask the user a structured question (the two-option design approval) | The `fablepowers_ask_approval` tool for the approval ask. Pi core has no general question tool: ask other questions in plain text and end your turn. |
| Track tasks | The plan file and the ledger `.fablepowers/<plan>/progress.md`. Pi has no todo tool. |
| Native worktree tool (create / exit) | None. Use `git worktree add` as `fablepowers:using-git-worktrees` describes. |
| Plugin root (where `skills/`, `agents/`, `hooks/` live) | The absolute path the bootstrap preamble names. For a git install that is the clone under `~/.pi/agent/git/`, the live root: editing your own checkout changes nothing until you update the install. |

Pi's own tools are `read`, `bash`, `edit` and `write` (plus optional `grep`, `find`, `ls`).

## Seats and `models.toml`

| Seat | Tier | `seat` value | Role prompt | Model |
|---|---|---|---|---|
| Implementer | frontier | `implementer` | `agents/implementer.md` | `[pi] implementer`, else the session model |
| Strict implementer | mid | `strict_implementer` | `agents/strict-implementer.md` | `[pi] strict_implementer`, else the session model |
| Reviewer | frontier | `reviewer` | `agents/reviewer.md` | `[pi] reviewer`, else the session model |

The seat table in the bootstrap is authoritative. It names each seat's model and thinking level, or says the seat is unpinned.

**`models.toml`.** `${XDG_CONFIG_HOME:-~/.config}/fablepowers/models.toml`. On Pi only the `[pi]` table is read; `[codex]` and `[opencode]` are ignored (and each of those harnesses ignores `[pi]`).

```toml
[pi]
implementer = "openrouter/deepseek/deepseek-v4-flash"
implementer_thinking = "high"
strict_implementer = "openrouter/qwen/qwen3.6-flash"
reviewer = "openrouter/anthropic/claude-x.1"
reviewer_thinking = "xhigh"
```

- Seat keys: `implementer`, `strict_implementer`, `reviewer`. A value is `provider/model-id`: the provider is the part before the first `/`, the model id is the rest and may contain `/`. At most 128 characters from `A-Z a-z 0-9 . _ : @ - /`, with a non-empty provider and non-empty path segments. Values are double-quoted; `#` comments, CRLF and a UTF-8 BOM are fine; a duplicate key warns and the last one wins.
- A trailing thinking suffix (`…:high`, any of the levels below) is rejected: use `<seat>_thinking`. Other colon suffixes, such as OpenRouter's `:free`, are part of the id.
- `<seat>_thinking` (`implementer_thinking`, `strict_implementer_thinking`, `reviewer_thinking`) is one of Pi's levels: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`. Anything else warns, and the seat runs on Pi's default thinking for its model. A pinned seat without `_thinking` also gets Pi's default for that model.
- `<seat>_thinking` for a seat with no pinned model warns and is ignored. `<seat>_effort` is not used on Pi: it warns and is ignored.
- An unset or rejected seat runs on the **session's model and thinking level**. The bootstrap lists the unpinned seats in one warning line, after at most three parser warnings. A missing file means every seat runs on the session model.
- The table is read when the extension starts a session, so a `models.toml` edit takes effect in the next Pi session (or after `/new` or `/reload`).

Pi itself only warns on an unknown model id or thinking level and carries on, so the validation above and the model check after dispatch (below) are what catch a typo.

## Dispatch

```
fablepowers_dispatch {
  seat: "implementer" | "strict_implementer" | "reviewer",
  task: "<the dispatch the skill describes: plan path and task heading, spec path, how to run the tests, commit convention, report path>",
  cwd: "<optional: a directory inside this repository or one of its linked worktrees>"
}
```

- **A separate Pi process per call.** The tool runs the same Pi the parent runs (same executable and version) as `pi --mode json -p --session-dir <child dir> -e <plugin-root> --fablepowers-child=1 [--model <provider/id>] [--thinking <level>] --append-system-prompt <role file> "Task: …"`, with stdin from `/dev/null`. The child gets the environment plus `FABLEPOWERS_PARENT_SESSION`, `FABLEPOWERS_SEAT` and `FABLEPOWERS_PARENT_PID`. The role file is the seat's `agents/<seat>.md` with its frontmatter stripped, behind a one-line header naming the seat and the plugin root. A task over 64 KiB goes in a temp file the task line points to.
- **Model.** A pinned seat runs on its `provider/model-id` and its pinned thinking level. An unpinned seat runs on the parent session's model and thinking level.
- **One at a time.** The tool is sequential: several calls in one assistant message run one after another, and Pi then runs every tool call in that message sequentially. A later call's gate check sees what an earlier call changed.
- **The child loads fablepowers too,** so the gate applies inside it. It gets no bootstrap and cannot dispatch: `fablepowers_dispatch` refuses in any process that has `FABLEPOWERS_PARENT_SESSION` set. A child is recognised by the `--fablepowers-child` flag and that variable together. If the extension fails to load in the child, Pi rejects the unknown flag and the child does not run.
- **`cwd`.** Its real path must be inside the parent's git toplevel or one of the worktrees `git worktree list` reports; anything else (including a symlink that leads out) is rejected before a child starts.
- **Result.** The child's last assistant text, capped at 50 KB with a note naming the child transcript when cut, then a footer with the seat, the model and thinking the child reported, the exit code and the child session file. `details` holds `{seat, model, usage, exitCode, childSessionFile}`. A failed child adds its exit code, its stop reason and the tail of its stderr (8 KB) to the result.
- **Model-mismatch warning.** For a pinned seat, the first assistant message the child reports is compared with the seat's `provider/model-id` and thinking level. A mismatch adds a warning line to the result; the dispatch itself is not failed. Treat it as a stop: tell the user the seat did not run on its pinned model, and point to `models.toml` instead of retrying on another model.
- **Child transcripts.** `<parent session directory>/fablepowers-children/<parent session id>/<timestamp>_<child id>.jsonl`. A parent running with `--no-session` puts them under `$TMPDIR/fablepowers-children/<parent session id>/`. The parent's session gets a `fablepowers-child` custom entry linking each child.
- **Stopping children.** When the parent session shuts down (normal exit, `/quit`, SIGTERM, SIGHUP, a session switch) or the dispatch is aborted (Esc in the TUI, RPC `abort`), each live child gets SIGTERM, then SIGKILL 5 s later if it is still running. An aborted dispatch returns an error. As a backstop, each child checks every 2 s whether its parent process is still alive; if not, it aborts its run and exits.
- **Reports.** Dispatches name a workspace path such as `.fablepowers/<plan>/reports/task-<n>.md`, as on Claude Code.

## Bootstrap

At `before_agent_start` the extension sets the system-prompt section `fablepowers_workflow` in **root** sessions only. Pi keeps it in every request and through compaction. It comes from `hooks/session-start --pi`, run once per session (3 s timeout), and holds:

- a preamble naming Pi, this file, the plugin root and the skill-name rule (`fablepowers:<x>` is `fablepowers-<x>`);
- the seat table and its warnings;
- the workflow map;

at most 8,000 characters in all.

The bootstrap degrades visibly:

- **No usable `python3`:** the first line reads `fablepowers approval gate disabled: python3 not found …`. The gate allows everything, and the approve command and approval tool say they recorded nothing.
- **No bash, or session-start failed or timed out:** a `fablepowers bootstrap degraded: …` line plus the workflow map, read directly. There is no seat table, so every seat runs on the session model.
- **`FABLEPOWERS_PARENT_SESSION` set without the child flag:** a note says so; that session is treated as a root that cannot dispatch.

## Approval mechanism

Same markers, states and rules as on Claude Code (`.fablepowers/<key>/pending` and `approved`, written only by the gate). The extension turns Pi's events into `harness: "pi"` payloads for `hooks/approval_gate.py` (2 s timeout per call). It blocks a tool call only on the gate's explicit deny; every handler fails open on its own errors and logs to `.fablepowers/gate.log`, because Pi treats a throwing handler as a block. Python 3.8+ is needed.

**Paths.** The extension resolves each `write` and `edit` path the way Pi's tools do (a leading `@` dropped, `~` expanded, `file://` URLs, against the session's `cwd`), rewrites the call's `path` to that absolute path, and sends it to the gate, which judges it against the git toplevel. So the gate and the tool see the same file. Reads (`read`, `ls`, `grep`, `find`) are never gated, so a reviewer can read while a design is pending.

**Pending.** A root session's `write` that creates `docs/specs/<name>.md` marks the design pending: the extension records whether the file existed at `tool_call`, and the gate marks it when the result is not an error. Overwrites, `edit` (which cannot create files on Pi), and writes from a child session don't. The pending notice is appended to the tool result the model sees. Create the spec with `write`, never through `bash`.

**What it blocks** (`tool_call` → `{block: true, reason}`; the reason reaches the model as the tool's error):

- While any design is pending: `fablepowers_dispatch` for any seat except `reviewer`. The seat is an argument of our own tool, so it is the seat that will run.
- While any design is pending: Pi's example `subagent` tool, whatever agent it names.
- While any design is pending: a `write` or `edit` to a repository path outside `docs/specs/`, `docs/plans/` and `.fablepowers/`, or with a missing or unresolvable path. Paths outside the repository stay allowed, except the two below.
- While any design is pending: Pi config, meaning anything under a `.pi` directory (the project's `.pi/`, `~/.pi/agent/`, anywhere), anything under `$PI_CODING_AGENT_DIR`, and `fablepowers/models.toml` under the config home.
- While any design is pending: anything under the plugin root.
- Always: an edit to a marker, with names compared as on Claude Code (case-insensitive, NTFS variants). Config, `models.toml` and plugin-root paths are compared the same way, and so is the repository itself: a case or NTFS-name variant of the toplevel counts as inside it.

**Approving.** Only the user approves, from the **main (root) session**, in one of two ways:

1. **Answer Approve in the approval dialog.** The model calls `fablepowers_ask_approval` (its `spec` argument is informational only). The tool asks the gate which designs are pending, then shows the user a dialog in the TUI, or over the RPC protocol: **Approve** / **Changes needed** for one design, or one `Approve <spec>` entry per design plus **Changes needed** for several. The gate records the user's choice inside the tool, after re-checking that the design is still pending and its spec still exists. The model controls only the arguments, never the answer. In print and json mode there is no UI: the tool shows no dialog and tells the model to ask the user for the command.
2. **Type `/fablepowers:approve [key]`** (the key is the spec's file name, with or without `.md`; one pending design needs none). This is an extension command: it runs without a model turn, in the TUI and in print mode (`pi -c -p '/fablepowers:approve'` continues the session). The gate's answer goes to the session as a `fablepowers-result` message the model sees on its next turn, and to the user as a notification in the TUI and RPC or one stderr line in print and json mode.

With several designs pending and no key, or an unknown key, nothing is recorded and the answer lists the keys. An approval's answer names the next step (the `fablepowers-implementation-plan` skill).

**Refusals.** The command and the approval tool record nothing, and say why, when:

- the session is a dispatched child (or the extension could not tell); or
- `PI_SESSION_ID` is in the environment, in any mode, the TUI included. Pi's `bash` tool exports `PI_SESSION_ID` to everything it runs, so a `pi -c -p '/fablepowers:approve'` the model starts through its shell is refused, and so is a TUI `pi` it starts under a pty (`script -qec …`). A user who runs Pi from inside another Pi's shell (`!pi`), or from any terminal opened from one (a tmux server or an editor started there inherits `PI_SESSION_ID`), is refused too and approves from a Pi started in their own terminal instead.

**Withdrawing.** `/fablepowers:withdraw [key]`, by the same rules. The spec file stays.

**Escape hatch.** `FABLEPOWERS_GATE=off` in Pi's environment turns denies into `.fablepowers/gate.log` lines.

### Asking for approval

Design-spec's brief, then the approval ask in a separate call: `fablepowers_ask_approval`. Close the brief with: answer **Approve** in the dialog, or run `/fablepowers:approve`. In print or json mode the tool shows no dialog; ask in plain text and end your turn, and the user continues with `pi -c -p '/fablepowers:approve'`.

### Differences from Claude Code

| | Claude Code | Pi |
|---|---|---|
| Spec create | Write tool create | `write` that creates the file (existence checked at `tool_call`) |
| Approval | answer Approve, or `/fablepowers:approve` | Approve in the `fablepowers_ask_approval` dialog (TUI, RPC), or `/fablepowers:approve` |
| Dispatch gated | Agent `subagent_type` implementer / strict-implementer | `fablepowers_dispatch` except seat `reviewer`; the example `subagent` tool always |
| Config guard | `.claude/settings*.json` | `.pi/` anywhere, `$PI_CODING_AGENT_DIR`, `fablepowers/models.toml`, the plugin root |
| Model can't approve because | `disable-model-invocation: true` | commands aren't reachable from tools; a shell-started `pi` carries `PI_SESSION_ID`; the dialog answer is the user's |

## Requirements

- **Python 3.8+** for the gate: `FABLEPOWERS_PYTHON` as the only candidate when set; otherwise `python3` on PATH, then `/usr/bin/python3`, `/usr/local/bin/python3`, `/opt/homebrew/bin/python3`.
- **bash** for the seat table: `FABLEPOWERS_BASH`, then PATH, then `/bin/bash`, `/usr/bin/bash`, `/usr/local/bin/bash`, `/opt/homebrew/bin/bash`.
- Node.js only as Pi itself needs it. The extension's tests use `node --test`.
- Headless runs: `pi -p "…" < /dev/null`. With a piped stdin that never closes, `pi -p` waits on it before the session starts.

## Accepted gaps

The gate stops a session rolling past approval. It is not a sandbox. Not covered:

- **Shell writes.** `bash` is not gated. A shell command can write files, forge or delete markers, or write a spec that is then never marked pending.
- **`env -u PI_SESSION_ID`.** A model that runs `env -u PI_SESSION_ID pi -c -p '/fablepowers:approve'` through its shell is not refused. That is deliberate evasion, the same class as forging a marker through the shell.
- **Launchers that don't set `PI_SESSION_ID`.** A process started some other way than Pi's `bash` tool (another extension's tool, an MCP server, a script the model left running) carries no `PI_SESSION_ID`, so a `pi -p '/fablepowers:approve'` it runs is not refused.
- **The plugin outside pending.** Edits under the plugin root are denied only while a design is pending. At other times an edit to the installed package is not blocked, and it could disable the gate before the next design.
- **Third-party dispatch packages.** Only `fablepowers_dispatch` and the example's `subagent` tool are gated. Another package's dispatch tool is not.
- **MCP and code-mode writes.** Only Pi's `write` and `edit` are gated. A file written by an MCP tool or another extension's tool is not.
- **SIGINT or SIGKILL of a print-mode parent.** Pi fires no shutdown event for either. Live children are not signalled; each one notices within about 2 s that its parent is gone and exits, but work it finishes in that window (a commit) stands.

## Session logs

Sessions are JSONL files under `~/.pi/agent/sessions/--<cwd>--/<timestamp>_<id>.jsonl` (or `--session-dir`). Each assistant message records `provider`, `model`, `thinkingLevel` and `usage`, so the model a seat ran on is in its child transcript under `fablepowers-children/`. The gate's own log, including the extension's `pi extension: …` lines and each child's `loaded in child seat=…` line, is `<repo>/.fablepowers/gate.log`. `scripts/analyze_delegation.py --harness pi` (in the repo) reads both layouts read-only, `--pi-sessions` to point elsewhere; it links children by the parent's `fablepowers-child` entry, else by the `fablepowers-children/<parent-id>/` directory, and uses Pi's recorded cost. A `/fork` or `/clone` (a session whose header names its source file in `parentSession`) repeats the source's entries with their ids; the script counts those once, in the source, and the fork's row only its new entries.
