# Session-log fixtures for `scripts/analyze_delegation.py`

The fixtures cover four harnesses: Claude Code (`cc`), Codex (`cx`), OpenCode (`oc`) and Pi (`pi`).

There are two kinds:

- **Sanitised real logs.** These come from the fablepowers spike and test sessions of 2026-10-14 to 2026-10-17, run through `scripts/sanitize_fixture.py`.
- **Synthetic records.** `make_synthetic.py` writes them. Run it again after editing it; the output is deterministic.

`tests/analysis/test-fixture-privacy.sh` guards everything in this directory. It fails on home or scratch paths, the username, email addresses, other projects, dropped keys and long free text.

The expected values below were **derived by hand**. They come from counting the fixture records with the rule named in each column, not from running a reader. Where a value depends on a rule the plan leaves to Tasks 3–5, the row says so. Those cells are marked "open".

## Shared rules

These rules come from the spec's binding resolutions and the plan-review resolutions.

- **date:** the UTC date of the session's first timestamp.
  - Codex: `session_meta.timestamp`.
  - OpenCode: `session_v2.time_created`.
  - Pi: the header `timestamp`.
- **out:** main-loop output tokens.
  - Codex: the last `token_usage_record.thread_token_usage.output_tokens`, which equals the sum of `usage.output_tokens`.
  - OpenCode: `output + reasoning`, summed over the `assistant` and `compaction` messages in `session_message`.
  - Pi: the sum of `usage.output`.
- **subs:** every descendant, rolled up into the root. Depth 2 is rolled up too.
- **spawn model:**
  - Codex: the requested id.
  - OpenCode and Pi seats (`fablepowers-<seat>` agents, `fablepowers_dispatch`): `seat`, unless the call passes a model.
  - Anything else with no model: `None`, printed as `(unset)`.
- **gap:** user turns from the first design-spec load to the first edit that is not a spec or plan, a shell write, or an implementation-plan load.
  - A Pi approval result counts as one turn (resolution M1).
  - Withdraw and not-recorded results do not count.
- **cost:**
  - Codex: `None`.
  - OpenCode: the recorded per-message `cost`.
  - Pi: the sum of `usage.cost.total`.

## Claude Code — `claude/projects/` (fully synthetic)

**Purpose:** the byte-identity baseline for `--harness claude` against the old script (`git show 8419058:scripts/analyze_delegation.py`).

The set is built to catch specific failures:

- **Path order differs from date order.** The rows print a1, b2, c3, but the dates are 10-12, 10-03, 10-07.
- **A main-model tie.** In c3, opus-5 and fable-5 each have 2 records, and opus-5 is inserted first.
- **A three-way sub-model tie** for `most_common(2)`. Which two print depends on glob order.
- **Records that are skipped:**
  - a `tool_result` user record and an `isMeta` user record;
  - a session with no timestamp (`empty.jsonl`);
  - a `memory/` project;
  - an empty subagent file (`b2/subagents/agent-z.jsonl`).
- **Every legacy column has a non-zero value.**

| row | date | project | main | usr | mainOut | subOut | sub% | mEdit | mBashW | sEdit | $main | $sub | apprv | skills | spawns |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| a1 | 2026-10-12 | fixture-alpha | sonnet-5 | 2 | 2,000 | 0 | 0% | 0 | 0 | 0 | 0 (0.12) | 0 | - | fp:verify-done,sp:brainstorming | |
| b2 | 2026-10-03 | fixture-alpha | gpt-unknown | 1 | 700 | 0 | 0% | 0 | 0 | 0 | 0 | 0 | 0 | design-spec,fp:implementation-plan | |
| c3 | 2026-10-07 | fixture-beta/feat-x | opus-5 | 4 | 57,000 | 9,000 | 14% | 2 | 1 | 3 | 4 (4.25) | 2 (2.095) | 2 | fp:design-spec | implementer@sonnetx1 reviewerx1 explorerx1 |

How the numbers are derived:

- **c3 cost.** The prices are $/MTok from `PRICE` in the old script.
  - opus-5: 200k input × 5 + 40k output × 25 = 2.00, plus 1M cache-read × 0.5 + 4k output × 25 = 0.60.
  - fable-5: 80k cache-write × 12.5 + 10k output × 50 = 1.50, plus 3k output × 50 = 0.15.
  - Total: 4.25.
- **c3 subs:**
  - sonnet-5: 1M input × 2 + 6k output × 10 = 2.06, with 2 edits.
  - haiku: 2k output × 5 = 0.01, with 1 edit.
  - opus-5: 1k output × 25 = 0.025, with 0 edits.
- **c3 gap.** The first design-spec load is followed by:
  - an AskUserQuestion;
  - a user turn (1);
  - a Write to `docs/specs/f1.md`, which doesn't stop the count;
  - the user turn `/fablepowers:approve` (2);
  - a Bash `cat >` write, which stops the count.
- **a1 cost.** 50k input × 2 + 1.5k output × 10 + 0.5k output × 10 = 0.12.
- **b2 gap.** The design-spec load is followed directly by implementation-plan, so the gap is 0. `gpt-unknown` has no price, so the cost is 0.

Summary lines:

- `sessions: 3 (all dates)`.
- Output: main 59,700, subs 9,000, share 13.1%.
- Edits: main 2, Bash writes 1, subs 3.
- Spend: main $4 (4.37), subs $2.
- Spawn model: `{'sonnet': 1, '(unset)': 2}`.
- Sub output by model: sonnet-5 6,000, haiku-4-5-20251001 2,000, opus-5 1,000.
- `--since 2026-10-05` drops b2.

## Codex — `codex/sessions/YYYY/MM/DD/` (sanitised real + synthetic)

The `YYYY/MM/DD` directories use **local** dates. 67db and 88c2 sit under `2026/10/14` but start at UTC 2026-10-15, so `--since 2026-10-15` must include them.

Edits and spawns count **attempts** (orchestrator ruling): every `tools.apply_patch(` / top-level `apply_patch` call and every spawn call counts, whether or not it ran. A FileChange item supplies the files of the call that ran (one edit per file); a CollabAgentToolCall supplies the requested model and the child of a v1 spawn. The orphan record's project prints as `(orphan) <proj>`.

Every real rollout includes the following:

- **A catalogue stub.** `world_state.host_skills` names `skills/design-spec/SKILL.md` without loading it. It must not count as a skill or as a gap start.
- **Non-user `response_item` role=user messages,** such as `environment_context` and `subagent_notification`. These are not user turns. User turns are counted from `item_completed` `UserMessage` items only.

| root (id prefix) | source | date | proj | main model | usr | out | cost | mEdit | mShellW | skills | spawns (role@model) | gap | subs (id: model, out, edits) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01a13e08-67db | real, v2 | 2026-10-15 | codex-repo | gpt-6-luna | 1 | 264 | None | 0 | 0 | — | 1 × implementer@None, printed `implementerx1` and `(unset)` in the summary (ruling: `agent_type` fp-implementer maps to implementer before the task name `tooling_spike`) | - | 75cd: gpt-5.6-terra, 344, 0; **85ec (depth 2, under 75cd)**: gpt-5.6-terra, 19, 0 → subOut 363 |
| 01a13e09-88c2 | real | 2026-10-15 | codex-repo | gpt-6-luna | 1 | 157 | None | 1 | 0 | — | — (`request_user_input` gives one `ask`) | - | — |
| 01a1400a-c958 | real, v1 | 2026-10-15 | codex2-repo | gpt-5.6-luna | 1 | 960 | None | **1** (ruling: attempts; one `tools.apply_patch` call with no FileChange) | 0 | fp:workflow, fp:subagent-execution | implementer@gpt-5.6-luna, other@gpt-5.6-luna (from `CollabAgentToolCall`) | - | eaed: gpt-5.6-luna, 218, **1** (an apply_patch attempt with no FileChange); 0093: gpt-5.6-luna, 5, 0 → 223, sEdit 1 |
| 01a1408c-3129 | real, v1 | 2026-10-15 | codex-port-t0-repo | gpt-5.6-luna | 1 | 339 | None | 1 | 0 | — | reviewer@gpt-5.6-luna (the child's first UserMessage is `fablepowers-seat: reviewer`) | - | 51ab: gpt-5.6-luna, 6, 0 |
| 01a1408d-0374 | real, **compaction** | 2026-10-15 | codex-port-t0-repo | gpt-6-luna (5 turn_contexts) | 3 | **103**; the last `token_count` total is 27, which is wrong | None | 0 | 0 | fp:approve (`$skill` selected twice) | — | - | — |
| 01a14920-3524 | real, v2 | 2026-10-17 | codex-r1 | gpt-6-luna | 4 | 4,026 | None | 3 | 0 | fp:approve, fp:implementation-plan, fp:subagent-execution, fp:behavioral-testing, fp:integration-review | 5 × gpt-6-luna: implementer ×3, reviewer ×2 (task names `fablepowers_<seat>_*`; implementer_t1 has no child rollout) | - | 9bfe 6; 0b6c 1,143; 70f4 835, 1 edit; 0e87 142 (all gpt-6-luna) → subOut 2,126, sEdit 1 |
| 01a1fe00-…01 | synthetic | 2026-10-18 | cx-synth | gpt-6-sol | 5 | 600 | None | 2 | 1 | fp:design-spec | reviewer@gpt-6-luna | **3** | …02: gpt-6-luna, 450 (records 400 + 50), 1 edit |
| `(orphan)` | synthetic …03 | 2026-10-18 | `(orphan) cx-synth` | — | — | — | — | — | — | — | — | - | …03: parent …ff is missing; gpt-6-luna, 70 |

Synthetic cases:

- **Gap in the synthetic root.** The first design-spec load (a `cat` of the SKILL.md) is followed by:
  - user turn (1);
  - `request_user_input` (an ask);
  - user turn (2);
  - a FileChange to `docs/specs/f1.md`, which doesn't stop the count;
  - user turn (3);
  - `cat >`, which stops the count.
  The 5th user turn and the `src/f2.py` FileChange come after the stop.
- **Truncated last line.** The synthetic root ends with a truncated line (a rollout caught mid-write). The reader must skip it without crashing.
- **Compressed rollout.** `…04.jsonl.zst` is a stub zstd file. The reader must skip it and add a note.
- **Missing session table (OpenCode).** No fixture covers a db without `session_v2`; the Task 4 test creates that db itself.

## OpenCode — `opencode/sanitised.sql`, then `opencode/synthetic.sql`

Load both files, in that order, into a temporary SQLite db.

- `sanitised.sql` carries the real DDL from the `opencode.db` `sqlite_master`, for `project`, `session_v2` and `session_message` and their indexes.
- The synthetic root's messages are inserted out of `seq` order, so the reader must use `ORDER BY seq`.

Out is `output + reasoning` from `session_message`. The `session_v2` totals deliberately differ from it.

Edits (`edit`/`write` calls) and spawns (`subagent` calls without `input.sessionID`) count **attempts** (orchestrator ruling): errored calls count too. A `subagent` call with `input.sessionID` resumes an existing child: neither a spawn nor a new sub. The main-model counter counts `assistant` and `compaction` messages (ec1f: 6 big-pickle). Subs are listed in `session_v2.time_created` order. The orphan record's project prints as `(orphan) <proj>`; its own cost is 0.00 (recorded, nothing spent in a main loop).

| root (id prefix) | source | date | proj | main | usr | out (session_v2) | cost | mEdit | mShellW | skills | spawns (role@model) | gap | subs (model, out, edits) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ses_ec1facbf4ffe | real, compaction | 2026-10-15 | opencode-scratch-repo | big-pickle | 3 | 1,923 = 1,563 + 360 (same in session_v2) | 0.0 | 0 | 0 | — | reviewer@opencode/mimo-v2.6-flash-free, implementer@opencode/nemotron-3.5-lightning-free (requested ids) | - | reviewer: mimo-v2.6-flash-free, 224, 0; implementer: mimo-v2.6-flash-free, 25, 0 → 249 |
| ses_ebd5a99f3ffe | real | 2026-10-16 | opencode-t0-repo | big-pickle | 2 | 1,160 = 788 + 372 (session_v2: 1,178) | 0.0 | 2 | 0 | fp-probe:base (a non-fablepowers skill id; listed, per the ruling "all skills") | 3 × other@(unset): `general`, `fp-seat-varmodel`, `fp-seat-varkey`. The `explore` call with `input.sessionID` is a **resume**, not a spawn | - | explore: big-pickle, 80, 1; fp-seat-varmodel: cat-jam-free, 26, 0; fp-seat-varkey: cat-jam-free, 25, 0 → 131 |
| ses_ebcf175dfffe | real | 2026-10-16 | opencode-t5-r1 | big-pickle | 3 | 7,750 = 7,078 + 672 (session_v2: 7,826) | 0.0 | **11** attempts (7 completed, 4 errored; ruling: attempts) | 0 | fp:implementation-plan, fp:subagent-execution, fp:integration-review, fp:verify-done | 5 attempts @seat: implementer ×2 (1 errored), reviewer ×3 | - | 4 children: 29; 898, 1 edit; 3,813, 4 edits; 651 → 5,391, sEdit 5 |
| ses_ebcec7c9bffe | real, `synthetic` msg | 2026-10-16 | opencode-t5-r2 | big-pickle | 2 (the `synthetic` message is not a turn) | 10,215 = 9,746 + 469 (session_v2: 10,550) | 0.0 | 7 | 0 | fp:implementation-plan, fp:subagent-execution, fp:integration-review, fp:verify-done, fp:finishing-a-development-branch | 4 attempts @seat: implementer ×2 (1 errored), reviewer ×2; `question` gives one ask | - | 1,812, 1 edit; 4,121, 5 edits; 1,083, 1 edit → 7,016, sEdit 7 |
| ses_fixture000000ocRootGap0001 | synthetic | 2026-10-18 | oc-synth | big-pickle (3, against gpt-oss-fixture 1) | 4 | 325 = 240 + 85 (session_v2: 999 + 111) | **2.50** (session_v2: 9.99) | 2 | 1 | fp:design-spec | implementer@seat; reviewer@(unset) (`general`, role from "review" in the description); reviewer@opencode/cat-jam-free. The 2nd implementer call (`sessionID` = …Impl001) is a resume, not a spawn | **2** | Impl001: deepseek-v4.1-flash-free, 250, 2 edits, $1.50; **Grandchild01 (depth 2)**: big-pickle, 30, 1 edit, $0.25; Genrl01: big-pickle, 10, 0; Revw001: cat-jam-free, 50, 0, $1.00 → subOut 340, sEdit 3, sub $2.75 |
| `(orphan)` | synthetic | 2026-10-18 | `(orphan) oc-synth` | — | — | — | — | — | — | — | — | - | Orphan00001 (parent …MissingPar01 is absent): cat-jam-free, 60, $1.00 |

**Gap in the synthetic root.** The first design-spec load (seq 2) is followed by:

- a `synthetic` message (seq 3), which is not a turn;
- a user message (1);
- a `question`;
- a write to `docs/specs/f1.md`;
- the user message `/fablepowers:approve` (2);
- an edit to `src/f2.py`, which stops the count.

## Pi — `pi/flat/` (`--session-dir` layout, sanitised real) and `pi/default/` (`--<cwd>--` layout, synthetic)

Both layouts include `fablepowers-children/<parent-id>/` directories. A reader that globs for roots recursively without excluding those directories counts the children as roots. `pi/default/--fixture-pi-synth--/notes.txt` is a non-session file and must be ignored.

| root (id prefix) | source | date | proj | main | usr | out | cost | mEdit | mShellW | skills | spawns | gap | subs (model, out, cost, edits) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01a14830-e336 | real (pi2) | 2026-10-17 | pi2-work | deepseek/deepseek-v4-flash | 1 | 8 | 0.00005 | 0 | 0 | nsdemo (a `<skill name="fablepowers:nsdemo">` user message, so a skill event and a user turn) | — | - | — |
| 01a1486c-da07 | real (pi-t0) | 2026-10-17 | pi-t0-work | deepseek/deepseek-v4-flash | 1 | 462 | 0.000902 | 1 | 0 | — | reviewer@seat, implementer@seat. The 3 `subagent` tool calls, from a non-fablepowers extension, are not spawns | - | — (no children directory) |
| 01a14919-850c | real (pi-t5) | 2026-10-17 | pi-t5-r1 | deepseek/deepseek-v4-flash | 3 | 925 | 0.00183 | 1 | 0 | — | implementer@seat (this call errored), reviewer@seat, implementer@seat | - (there is an approved result but no design-spec load) | 9b68 (`fablepowers-child` entry): gemini-3.1-flash-lite, 2, 0.001295, 0; b8fa (entry): qwen3.6-flash, 2,752, 0.01368, 2 → subOut 2,754, sEdit 2 |
| 01a14919-d69c | real (pi-t5) | 2026-10-17 | pi-t5-r2 | deepseek/deepseek-v4-flash | 3 | 612 | 0.001366 | 1 | 0 | — | — (`fablepowers_ask_approval` gives one ask) | - | — |
| 01a1491a-1892 | real (pi-t5) | 2026-10-17 | pi-t5-r1 | deepseek/deepseek-v4-flash | 2 | 295 | 0.000845 | 2 | 0 | — | — (one ask; a withdraw result) | - | — |
| 01a1491b-ad38 | real, **killed parent** | 2026-10-17 | pi-t5-r4 | deepseek/deepseek-v4-flash | 1 | 129 | 0.000398 | 0 | 0 | — | implementer@seat | - | b9ba (**directory only, no entry**): qwen3.6-flash, 121, 0.001089, 0 |
| 01a1fe10-…01 | synthetic, default layout | 2026-10-18 | pi-synth | deepseek/deepseek-v4-flash | 3 | 250 | **2.25** | 2 | 1 | fp:design-spec (wrapper read plus SKILL.md read, deduplicated), fp:verify-done (`/skill:` message) | implementer@seat, reviewer@seat | **3** | …02 (entry): qwen3.6-flash, 300, 2.20, 2 edits; …03 (directory only): gemini-3.1-flash-lite, 40, 1.05, 0 → subOut 340, sub $3.25, sEdit 2 |
| `(orphan)` | synthetic …04 | 2026-10-18 | pi-synth | — | — | — | — | — | — | — | — | - | …04 under `fablepowers-children/…ff/`, whose parent is missing: qwen3.6-flash, 60, 1.00 |

**Gap in the synthetic root.** The first design-spec load (the `read` of the `fablepowers-design-spec` wrapper) is followed by:

- a user turn (1);
- `fablepowers_ask_approval`;
- a write to `docs/specs/f1.md`;
- a **withdrew** result, which doesn't count;
- a **not recorded** result, which doesn't count;
- an **approved** result (2);
- the `/skill:` message for verify-done (3);
- a bash `cat >`, which stops the count.

The `user_turns` column counts only user messages, so it is 3. An approval result adds to the gap only.

Real approval results in the fixtures:

- 850c: approved.
- d69c: approved, plus 2 results with "recorded nothing" / "not recorded" wording.
- 1892: withdrew.

## Rebuilding

```
python3 scripts/sanitize_fixture.py codex <rollout.jsonl>... --out tests/analysis/fixtures/codex
python3 scripts/sanitize_fixture.py opencode --db <opencode.db> --session <root ids> --out tests/analysis/fixtures/opencode/sanitised.sql
python3 scripts/sanitize_fixture.py pi <session.jsonl>... --root <session dir> --out tests/analysis/fixtures/pi/flat
python3 tests/analysis/fixtures/make_synthetic.py
python3 scripts/sanitize_fixture.py check {codex|pi} RAW SANITISED   # signal equality (M2)
bash tests/analysis/test-fixture-privacy.sh
```

The real sources are never committed.

- The Codex rollouts and the OpenCode db are local to the machine that made them.
- The Pi spike logs are kept under `.fablepowers/` (gitignored).
