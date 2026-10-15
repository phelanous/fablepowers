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
the gate turns itself off and everything else still works; it warns (once per
session) only in repositories that already have a `.fablepowers/` directory.

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
Other harnesses get a sibling reference when their support lands.

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
design is pending, the edit tools are blocked from repo code and from Claude
Code settings files (`.claude/settings.json`, `.claude/settings.local.json`,
in any location), but a model writing through the shell could still forge or
delete a marker or install a settings hook that answers the question for the
user. Details:
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
