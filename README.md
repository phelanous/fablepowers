# fablepowers

A fork of [superpowers](https://github.com/obra/superpowers) for frontier
orchestrator models. Same shape — design, plan, execute, review, verify — but
the rituals are replaced by outcomes: instead of "write the test first", *every
behavior in the spec has a test proven to fail when that behavior is broken*;
instead of a hard gate on every step, two rigid gates (fresh-context integration
review before merge, executed verification before any "done") plus one user
checkpoint (explicit design approval). Strictness is model-conditional: the
orchestrating model gets judgment and checkpoints, weaker implementer subagents
get the original imperative rails. Implementer and reviewer are **named agents
with pinned models**, so who does the work is a fact in a definition file rather
than a hope in a prompt. The name is a joke about the author's default model;
the design is model-tiered and works with any frontier orchestrator. Every rule
here came out of a log audit — see [`docs/rationale.md`](docs/rationale.md).

## Install

```
/plugin marketplace add phelanous/fablepowers
/plugin install fablepowers@fablepowers
```

Nothing else to configure. A SessionStart hook loads the workflow map into every
new session, so the model knows the entry point without any CLAUDE.md edits.

**Requirements:** Claude Code 2.1.299 or later (the version the approval gate is
tested with; the approve and withdraw commands rely on its `UserPromptExpansion`
hook event), and Python 3.8+ for the approval gate. Without a usable `python3`
the gate turns itself off and everything else still works. It then warns once
per session: on any hooked call in a repository that has a `.fablepowers/`
directory, and elsewhere in a repository on the calls where the gate would have
acted (creating a spec under `docs/specs/`, the approval question, and
`/fablepowers:approve` or `/fablepowers:withdraw`).

## Codex

fablepowers also runs in OpenAI Codex (CLI and app; tested with Codex CLI
0.162.1), from the same repository: the same skills, seats, approval gate and
workflow map. What the skills' actions resolve to on Codex is in
[`skills/workflow/references/codex.md`](skills/workflow/references/codex.md).

**Install.**

```
codex plugin marketplace add phelanous/fablepowers
codex plugin add fablepowers@fablepowers
```

**Trust the hooks once.** Codex runs a plugin's hooks only after you trust them:
open `/hooks` in the Codex CLI and trust the fablepowers entries. Until then
there is no workflow map and no approval gate. Trust is kept per hook entry, so
trust again after an update that changes `hooks/hooks.json`. Upgrading from
0.4.0 keeps the eight entries you already trusted and adds three new ones (the
two spawn tools and `UserPromptSubmit`) to trust. For headless runs,
`scripts/codex-hook-trust.sh` prints a one-run override instead (read-only; it
never writes your config). On any error it prints nothing on stdout and exits
1, so check its status rather than passing an empty `-c ""`:

```
trust="$(scripts/codex-hook-trust.sh fablepowers@fablepowers)" || exit 1
codex -c "$trust" exec …
```

**Let agents commit (optional).** Under Codex's `workspace-write` sandbox `.git`
is read-only, so each `git add` and `git commit` asks for approval. Copy
[`codex/rules/fablepowers.rules`](codex/rules/fablepowers.rules) to your
project's `.codex/rules/` or to `~/.codex/rules/` to allow plain `git add`,
`git commit` and `git worktree add`. `git push`, `git -c … commit` and other git
commands still ask. Project rules apply only when the project is trusted in
`~/.codex/config.toml`; Codex adds that entry on the first trusted session
there. A `-c projects."<path>".trust_level="trusted"` override is not honoured
for project rules on `codex exec resume`, so for headless runs trust the
project once (or use `~/.codex/rules/`).

**Seat models (optional).** By default the implementer and reviewer run on
`gpt-6.1-sol` (effort high) and the strict implementer on `gpt-5.6-terra`
(effort medium). Sol needs an account with Sol access, and the Sol id comes from
the Codex binary's catalog, so verify it with `codex debug models`. Override any
seat in `~/.config/fablepowers/models.toml` (or under `$XDG_CONFIG_HOME`):

```toml
[codex]
implementer = "gpt-6-luna"
implementer_effort = "medium"
reviewer = "gpt-6-luna"
```

Keys are `implementer`, `strict_implementer`, `reviewer` and `<seat>_effort`;
values are double-quoted; efforts are `low`, `medium`, `high`, `xhigh`, `max` or
`ultra`. A bad entry falls back to the default and shows a warning in the
session's injected context. If a seat's model is unavailable, the session stops
and asks you to set it here.

**Approving a design.** There is no approval question on Codex. Reply with
`$fablepowers:approve` as the whole message (add the spec's key when several
designs are pending); `$fablepowers:withdraw [key]` drops one. Type it, or pick
it from the `$` menu in the CLI; in the Codex app, type it as text, since a
skill picked from the app's menu does not reach the gate. In `codex exec`, the
run ends at the ask; continue with
`codex exec resume <session-id> '$fablepowers:approve'`. While a design is
pending, every spawn except a fablepowers reviewer is denied, as are patches
outside `docs/specs/`, `docs/plans/` and `.fablepowers/` and patches to Codex
config (`.codex/config.toml`, `.codex/rules/`, `.codex/agents/`,
`.codex/hooks*`). If an approval doesn't register, check that the hooks are
trusted, or set `FABLEPOWERS_GATE=off`. The accepted gaps (shell writes, a
spawn mislabelled as a reviewer, the rest of `~/.codex` and the plugin cache)
are listed in the Codex reference.

## OpenCode

fablepowers also runs in OpenCode 2.x (tested with OpenCode 2.0.29), from the
same repository, with the same skills, seats, approval gate and workflow map.
It runs as a plugin (`opencode/index.js`). The plugin's gate decisions come
from the same `hooks/approval_gate.py`, and its seat table from the same
`hooks/session-start`. What the skills' actions resolve to on OpenCode is in
[`skills/workflow/references/opencode.md`](skills/workflow/references/opencode.md).

**Install.** Add the plugin to the `plugins` key (OpenCode 2's key, not 1.x's
`plugin`) of an OpenCode config file. For every project, that is
`~/.config/opencode/opencode.json`. For one project, use the project's
`opencode.json` or `.opencode/opencode.json`.

```json
{ "plugins": ["fablepowers@git+https://github.com/phelanous/fablepowers.git"] }
```

To pin a release, append its tag: `…/fablepowers.git#v0.6.0`. OpenCode
installs the plugin into its cache on the next run. Then restart OpenCode,
including its background service (`opencode serve --service`) if one is
running, because plugins load when the server starts. If superpowers is
installed in OpenCode too, remove it: both preambles arrive with conflicting
instructions, the same conflict as on Claude Code (see [Migrating](#migrating)).

**Requirements.** Python 3.8+ for the approval gate, and bash for the
bootstrap's seat table. Without python the gate is off, and the bootstrap says
so in its first line. Without bash there is no seat table, so every seat runs
on the session model, and the workflow map is still injected. The plugin sees
the OpenCode **server's** environment. The background service keeps the PATH
of whatever started it, so if python or bash is found only through your
interactive shell, set `FABLEPOWERS_PYTHON` or `FABLEPOWERS_BASH` where the
server starts. The usual absolute locations (`/usr/bin`, `/usr/local/bin`,
`/opt/homebrew/bin`, and `/bin` for bash) are tried as fallbacks.

**Seat models (optional).** On OpenCode a seat with no entry runs on your
session's model, and the bootstrap names the unpinned seats in a warning line.
Pin seats in `~/.config/fablepowers/models.toml` (or under `$XDG_CONFIG_HOME`),
in its `[opencode]` table:

```toml
[opencode]
implementer = "opencode/big-pickle#high"
strict_implementer = "opencode/mimo-v2.6-flash-free"
reviewer = "openrouter/anthropic/claude-x.1"
```

Keys are `implementer`, `strict_implementer` and `reviewer`. A value is
`provider/model` with an optional `#variant` (the model's reasoning variant),
double-quoted, at most 128 characters. There are no `*_effort` keys here: use
`#variant`. A bad entry leaves that seat on the session model and shows a
warning in the bootstrap. Codex's `[codex]` table can sit in the same file, and
each harness reads only its own table. **Restart OpenCode after editing
`models.toml`, including the background service.** Seats load when the server
loads the plugin, not per session. A pinned seat keeps its model even when the
orchestrator passes a different `model` in a dispatch.

**Approving a design.** The design question blocks in the TUI: answer
**Approve**. Or type `/fablepowers:approve` in the TUI (add the spec's key
when several designs are pending); `/fablepowers:withdraw [key]` drops one.
`opencode run` doesn't route slash commands, and its question is cancelled, so
headless runs end at the ask. Continue with the command as the whole message of
the main session: `opencode run -s <session-id> /fablepowers:approve`. Only
the main session approves; a command or answer from a subagent session records
nothing. While a design is pending, every dispatch except
`fablepowers-reviewer` and the read-only `explore` agent is denied. So are
edits outside `docs/specs/`, `docs/plans/` and `.fablepowers/`, edits to
OpenCode config (`opencode.json`, `opencode.jsonc`, `.opencode/`,
`~/.config/opencode/`, `models.toml`), and edits to the plugin itself. Set
`FABLEPOWERS_GATE=off` in the server's environment to turn blocking off.

**Accepted gaps.** The full list is in the OpenCode reference:

- shell writes;
- the model approving itself by running `opencode run -s … /fablepowers:approve`
  or the server API through the shell;
- edits to the installed plugin while no design is pending;
- config in locations the guard doesn't list;
- another plugin's permission hook overriding a deny.

**Testing a checkout.** Plain `opencode` commands go to the background
service, which runs the installed plugin. To try a local checkout, list its
absolute path in `plugins` (the repository's root `index.js` is the
local-directory entry) and run `opencode run --standalone …`, which starts a
private server for that run.

## How it works

Ten workflow skills, invoked through the Skill tool as `fablepowers:<name>`, plus
two user-only commands, `/fablepowers:approve` and `/fablepowers:withdraw` (see
[The approval gate](#the-approval-gate)). The three agents are dispatched with the
Agent tool as `subagent_type: "fablepowers:<agent>"`.

The skills and agent bodies are written in harness-neutral terms ("dispatch the
implementer seat", "ask the user a two-option question"). What those resolve to
on Claude Code — tools, models, hooks, the approval mechanism, where session
logs live — is in
[`skills/workflow/references/claude-code.md`](skills/workflow/references/claude-code.md).
On Codex they resolve as described in
[`skills/workflow/references/codex.md`](skills/workflow/references/codex.md)
(see [Codex](#codex)), and on OpenCode as described in
[`skills/workflow/references/opencode.md`](skills/workflow/references/opencode.md)
(see [OpenCode](#opencode)).

| | |
|---|---|
| `fablepowers:workflow` | The map. Start substantive dev work here; it routes to everything below. |
| `fablepowers:design-spec` | Turn an idea into a written design through dialogue, scaled to the size of the work. Asks which platform, language and library choices the user wants to own. Substantial specs get a **builder check** — a fresh reviewer lists what a builder would still have to guess, and the build-changing questions go to the user in one round. Ends with a phone-readable design brief and a two-option approval ask — the user's explicit yes, never inferred from an answer to a design question, and enforced by the approval gate. |
| `fablepowers:implementation-plan` | Turn the approved spec into an interface-level plan: contracts, invariants, test obligations per task. No code in the plan. A **Review Focus** section names up to five spec-implied inputs no task tests yet, each assigned to the task that owns the code; plan review checks it. |
| `fablepowers:subagent-execution` | Dispatch one fresh implementer agent per plan task. The orchestrator coordinates and spot-checks; it does not implement. Dispatches name the plan path and task heading instead of pasting the task; agents write full reports to files and return at most 15 lines; a progress ledger lets a resumed session skip finished tasks. |
| `fablepowers:behavioral-testing` | Every spec behavior gets a test, and you break the behavior to watch that test fail. Ordering is free; the mutation check is not. |
| `fablepowers:integration-review` | **Rigid gate.** Before any merge, a fresh-context adversarial reviewer hunts the integration seams — inert knobs, migration/model parity, deployment config, contract drift. It gets a review package diffed from the merge-base, ends its report with what it declined to judge, and the orchestrator closes with the **Rulings I made** on the user's behalf. Capped at two re-reviews. |
| `fablepowers:verify-done` | **Rigid gate.** No "done", "fixed", or "passing" without running the command now and reading the output. |
| `fablepowers:systematic-debugging` | Vendored from superpowers v7.0.0, unchanged in substance. |
| `fablepowers:using-git-worktrees` | Vendored from superpowers v7.0.0. Adapted: an `implementation-plan` worktree request counts as consent; worktrees go under the project root. |
| `fablepowers:finishing-a-development-branch` | Vendored from superpowers v7.0.0. Adapted: PRs via `gh`, `fj` (Forgejo) or `glab`; cleanup only removes worktrees under the project root's `.worktrees/` or `worktrees/`, never host-owned ones. |

The approval ask is preceded by a short plain-language brief — what changes,
the decisions made, the risk, and when the spec is worth opening — so it can be
judged from a phone.

### The approval gate

The design-approval checkpoint is enforced by a hook, not just asked for in the
skill text. When the session creates a new spec file under `docs/specs/` (small
designs write a short one too), the hook marks that design **pending**. While
any design is pending, dispatching `fablepowers:implementer` or
`fablepowers:strict-implementer` and editing files outside `docs/specs/`,
`docs/plans/` and `.fablepowers/` are blocked, and the block message tells the
model to stop and ask the user. Reviewer dispatch, spec and plan edits, and
files outside the repository stay open.

Only a user action lifts it:

- **Answer Approve** to the design question (exactly the options Approve and
  Changes needed, with one design pending), or
- **Run `/fablepowers:approve`** — with no argument when one design is pending,
  or `/fablepowers:approve <key>` (the spec's file name, with or without `.md`)
  when several are. This is the path in headless runs.

Changes needed leaves the design pending. `/fablepowers:withdraw [key]` drops an
abandoned design (the spec file stays). Both commands are user-only: the model
cannot invoke them. Markers live in `.fablepowers/<key>/` (`pending`,
`approved`), are written only by the hook, and the model's edit tools may not
touch them. Once a design is approved the gate is quiet for it, so spec and plan
amendments during implementation are never blocked. Repositories with no pending
design (and specs kept outside `docs/specs/`) are never gated.

`FABLEPOWERS_GATE=off` in the environment turns blocking off (for emergencies
or CI); what would have been blocked is logged to `.fablepowers/gate.log`.

The gate stops a session that rolls past approval; it is not a sandbox. It
watches the edit tools and the agent dispatch, not shell commands. While a
design is pending, the edit tools are blocked from repo code and from the usual
Claude Code settings files (`.claude/settings.json`, `.claude/settings.local.json`,
in any location). That closes the common settings files only: an edit-tool
write to the installed plugin's own hook files, to a config directory not named
`.claude`, or to managed settings is not blocked, and is covered only by Claude
Code's own permission prompt for paths outside the project. A model writing
through the shell could also still forge or delete a marker or install a hook
that answers the question for the user. These are adversarial paths, outside
what the gate is for. Details:
[`skills/workflow/references/claude-code.md`](skills/workflow/references/claude-code.md#approval-mechanism).

The usual path: `workflow` → `design-spec` (approval) → `implementation-plan`
(plan review) → `subagent-execution` (implementers, one per task) →
`integration-review` (gate) → `verify-done` (gate) →
`finishing-a-development-branch`.

## Who does what

| Role | Agent | Model | Does |
|---|---|---|---|
| Orchestrator | the user's session | whatever the session runs | design dialogue, plan, dispatch, spot-check, fix-loop decisions, user communication. **Never implements a plan task.** |
| Implementer | `fablepowers:implementer` | Opus | one plan task per dispatch, fresh context, behavioral tests with the mutation check, commit, report |
| Strict implementer | `fablepowers:strict-implementer` | Sonnet | mechanical, fully specified tasks under the imperative red-green prompt; followed by a spec-check |
| Reviewer | `fablepowers:reviewer` | Opus | plan review, integration review, spec-check, builder check of a substantial spec; fresh context; never an agent that implemented anything in the feature |

A fully briefed single-session task still dispatches implementers. The
orchestrator's job is the plan, the dispatch and the judgment calls — the
default general-purpose agent inherits the orchestrator's model and effort, so
spawning one is not delegation. None of the three agents can spawn agents of
its own (`disallowedTools: Agent`): a sub-spawn would run on the parent's
inherited model.

### Handoff files

Execution and review hand work off through files in a per-plan workspace,
`.fablepowers/<plan-basename>/` at the top level of the worktree doing the work
(the approval gate's markers share the directory, keyed on the spec name):
`progress.md` (the orchestrator's ledger: one line per checked task and per
integration review and fix round, so a resumed session knows what ran),
`reports/` (implementer, reviewer and `integration-fix<k>` reports) and
`review-*.diff` (integration-review packages). Work with no plan keys the
workspace on its spec file, or on `@<branch-name>` when there is no spec either (each `/`
becomes `-`, so `@feat/x` and `@feat-x` share a workspace). The directory
ignores itself — `.fablepowers/.gitignore` containing `*` is written only if the
repo doesn't already have one — so nothing shows up in `git status`. It is left
in place after the feature and is safe to delete once the branch is merged.

## What changed from superpowers

| Skill | Replaces | What changed |
|---|---|---|
| `workflow` | using-superpowers | A map plus the philosophy and the gates. No "1% rule", no mandatory-invocation preamble. Adds the who-does-what table above. |
| `design-spec` | brainstorming | Same dialogue, tiered by size (user-visible behavior is never trivial). No HARD-GATE theater; instead one blocking user checkpoint, enforced by a hook rather than by wording, and the approval ask is preceded by a design brief and offers only Approve or Changes needed. |
| `implementation-plan` | writing-plans | Interface level — contracts, invariants, test obligations, PR-sized tasks — and **no code in the plan**. Adds an up-front plan review. The header names the implementing agent, not a "tier". |
| `subagent-execution` | subagent-driven-development, executing-plans | Fresh implementer per task kept. Per-task spec review only for the strict tier. Every dispatch names an agent type; the orchestrator never implements a plan task. |
| `behavioral-testing` | test-driven-development | TDD-as-ritual replaced by a rigid outcome plus a mutation check. Ordering free for frontier models; strict red-green retained for weak subagents and for bug fixes, where the failing test is the reproduction. |
| `integration-review` | requesting-code-review | Rigid gate, fresh-context adversarial reviewer that must execute the code, seam-focused checklist, ranked findings. Adds a two-round re-review cap. |
| `verify-done` | verification-before-completion | Condensed, unchanged in spirit. Rigid gate. |

Dropped on purpose: per-task spec-compliance review of a frontier-model plan
(~90% rubber-stamp rate in the logs); code-in-plan at 2–5-minute granularity;
TDD as an Iron Law; coercive framing; and the orchestrator as implementer.

`systematic-debugging`, `using-git-worktrees` and
`finishing-a-development-branch` are vendored from superpowers v7.0.0 with their
cross-references retargeted, so superpowers does not need to be installed
alongside this plugin. Two are adapted beyond that: `finishing-a-development-branch`
names the `gh`, `fj` and `glab` PR commands and anchors worktree cleanup at the
project root, and `using-git-worktrees` treats an `implementation-plan` worktree
request as consent.

## Tests

```
bash tests/systematic-debugging/test-find-polluter.sh   # vendored find-polluter.sh
bash tests/integration-review/test-review-package.sh    # workspace + review-package script
bash tests/hooks/test-session-start.sh                  # SessionStart hook, incl. with a broken PATH
bash tests/hooks/test-approval-gate.sh                  # approval gate hook, launcher and hooks.json wiring
bash tests/opencode/run.sh                              # OpenCode plugin (node --test; skips without node)
```

## Measuring it

The workflow's own claims are measurable, and the script that produced the
numbers in `docs/rationale.md` ships with the plugin:

```
python3 scripts/analyze_delegation.py --since 2026-08-01
```

It reads Claude Code's session transcripts under `~/.claude/projects`
(`--projects-dir` to point elsewhere; `--since YYYY-MM-DD` to window, default is
all sessions), pairs each session with its own subagent transcripts, and prints
one row per session plus a summary. Stdlib only, read-only.

| Column | Meaning |
|---|---|
| `usr` | user turns in the session |
| `mainOut` / `subOut` / `sub%` | output tokens produced by the orchestrator vs by its subagents, and the subagents' share. **This is the headline number**: work that stays in the main loop shows up here as a low `sub%`. |
| `mEdit` / `mBashW` / `sEdit` | who edited files — orchestrator Edit/Write calls, orchestrator writes smuggled through Bash heredocs and `sed -i`, and subagent Edit/Write calls |
| `$main` / `$sub` | rough cost estimate from the usage records (see the pricing note in the script; it is a June 2026 snapshot) |
| `apprv` | user turns between `design-spec` and the first implementation action. `-` means no design-spec. `0` is worth reading the transcript for. |
| `sub-models` | the model each subagent actually ran on |
| `skills` | skills invoked, in order |
| `spawns` | agent spawns by inferred role, annotated with the `model` param. **`(unset)` in the summary line means the subagent silently inherited the orchestrator's model** — that is the defect this plugin's pinned-model agents exist to fix. |

Useful before/after comparison: run it on a window from before you installed
this, then on a window after.

## Migrating

**From superpowers.** This plugin vendors the three superpowers skills it still
uses, so superpowers can be disabled once fablepowers is installed. Do disable
it: if both stay enabled, two SessionStart preambles arrive with conflicting
instructions — superpowers' requires invoking a skill before any response,
including clarifying questions, which contradicts this workflow's checkpoints.

**From a personal copy in `~/.claude/skills`.** Delete or rename the personal
skill directories that share a name with a plugin skill. Personal skills shadow
plugin skills at the bare name, so leaving them in place means you keep running
the old copies while believing you upgraded. Personal CLAUDE.md instructions
that describe the old workflow should go too — the SessionStart hook now carries
that content.

## Credits and license

The workflow this forks is [superpowers](https://github.com/obra/superpowers) by
Jesse Vincent, MIT licensed. Three of its skills are vendored here from v7.0.0,
two of them lightly adapted; the rest of the skills are rewrites informed by it. See
[`NOTICE`](NOTICE) for the attribution and the upstream license text.

This repository is MIT licensed — see [`LICENSE`](LICENSE).
