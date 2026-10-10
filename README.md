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

## How it works

Ten skills, invoked through the Skill tool as `fablepowers:<name>`. The three
agents are dispatched with the Agent tool as `subagent_type: "fablepowers:<agent>"`.

| | |
|---|---|
| `fablepowers:workflow` | The map. Start substantive dev work here; it routes to everything below. |
| `fablepowers:design-spec` | Turn an idea into a written design through dialogue, scaled to the size of the work. Ends with a phone-readable design brief and a two-option approval ask — the user's explicit yes, never inferred from an answer to a design question. |
| `fablepowers:implementation-plan` | Turn the approved spec into an interface-level plan: contracts, invariants, test obligations per task. No code in the plan. |
| `fablepowers:subagent-execution` | Dispatch one fresh implementer agent per plan task. The orchestrator coordinates and spot-checks; it does not implement. |
| `fablepowers:behavioral-testing` | Every spec behavior gets a test, and you break the behavior to watch that test fail. Ordering is free; the mutation check is not. |
| `fablepowers:integration-review` | **Rigid gate.** Before any merge, a fresh-context adversarial reviewer hunts the integration seams — inert knobs, migration/model parity, deployment config, contract drift. Capped at two re-reviews. |
| `fablepowers:verify-done` | **Rigid gate.** No "done", "fixed", or "passing" without running the command now and reading the output. |
| `fablepowers:systematic-debugging` | Vendored from superpowers v7.0.0, unchanged in substance. |
| `fablepowers:using-git-worktrees` | Vendored from superpowers v7.0.0. Adapted: an `implementation-plan` worktree request counts as consent; worktrees go under the project root. |
| `fablepowers:finishing-a-development-branch` | Vendored from superpowers v7.0.0. Adapted: PRs via `gh`, `fj` (Forgejo) or `glab`; cleanup only removes worktrees under the project root's `.worktrees/` or `worktrees/`, never host-owned ones. |

The approval ask is preceded by a short plain-language brief — what changes,
the decisions made, the risk, and when the spec is worth opening — so it can be
judged from a phone.

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
| Reviewer | `fablepowers:reviewer` | Opus | plan review, integration review, spec-check; fresh context; never an agent that implemented anything in the feature |

A fully briefed single-session task still dispatches implementers. The
orchestrator's job is the plan, the dispatch and the judgment calls — the
default general-purpose agent inherits the orchestrator's model and effort, so
spawning one is not delegation.

## What changed from superpowers

| Skill | Replaces | What changed |
|---|---|---|
| `workflow` | using-superpowers | A map plus the philosophy and the gates. No "1% rule", no mandatory-invocation preamble. Adds the who-does-what table above. |
| `design-spec` | brainstorming | Same dialogue, tiered by size (user-visible behavior is never trivial). No HARD-GATE theater; instead one blocking user checkpoint, and the approval ask is preceded by a design brief and offers only Approve or Changes needed. |
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
request as consent. The vendored `find-polluter.sh` has a test:

```
bash tests/systematic-debugging/test-find-polluter.sh
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
