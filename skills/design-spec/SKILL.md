---
name: design-spec
description: Use before implementing any new feature, component, or behavior change - collaborative dialogue to turn an idea into an approved spec, scaled to the size of the work.
---

# Design Spec

Turn an idea into a design the user has agreed to, through dialogue — before any implementation.

## Scale to the work

- **Trivial** (rename, config tweak, obvious one-liner): no spec doc. State your understanding in one sentence and proceed unless the user objects.
- **Small** (single-file feature, clear scope): a short spec file, not the full process. The brief from step 8 is the design summary: same headings, shorter, with "Open the spec if" replaced by "Ask me if" (what the user might want to weigh in on) and "Verified by" describing the tests directly. Write that brief to the spec directory as in step 5 — with the harness's file-write tool, never a shell redirect or heredoc, because only a file-write-tool create arms the approval gate — and commit it; creating the file is what puts the design under the gate. The ask is the same two-option question.
- **Substantial** (new subsystem, multi-file, ambiguous requirements): full process below.

Use judgment on which tier applies, with one hard rule: **anything that adds user-visible behavior is never trivial, and a new feature is substantial by default** — downgrade only with a stated reason the user can see. When requirements are ambiguous, that alone promotes it a tier — unexamined assumptions on "simple" work are where rework comes from.

## Process (substantial work)

1. **Explore context first** — relevant files, docs, recent commits. Ground questions in what exists.
2. **Ask clarifying questions in rounds** — one message per round, and let each answer shape the next question; the dialogue is the design tool, not a form to fill. Bundling several questions into one structured question is allowed only for independent cosmetic/presentation choices — never for requirements discovery, where the interesting question only becomes visible after the previous answer. For substantial work expect 3–6 rounds; stop when no remaining guess would change the design, not when you've exhausted question categories. One of the rounds asks **who owns the how**: which platform, language, library, or medium choices the user wants to make themselves. Whatever you default — including when the user hands every choice to you — goes under "Decisions I made" in the brief. (Upstream evidence: a session asked for an iOS app built a web app, and nobody had asked.)
3. **Propose 2–3 approaches** with trade-offs and a recommendation. If one approach is clearly right, say so and present it — don't manufacture alternatives.
4. **Present the design in sections** scaled to complexity; confirm direction as you go.
5. **Write the spec** to `docs/specs/YYYY-MM-DD-<topic>.md` and commit it. Create the file with the harness's file-write tool, never a shell redirect or heredoc: the gate sees only file-write-tool creates, so a spec written through the shell is never gated. Creating a new file there marks the design pending for the approval gate (where the harness has it; see the harness reference); a spec kept elsewhere by project convention is not gated. `docs/specs/` is for designs only — any new file there awaits approval, so put other notes elsewhere; the user's `/fablepowers:withdraw` clears a stray one. The spec states: goal, chosen approach, key contracts/behaviors, what's out of scope, and **how we'll know it works** (observable behaviors — these become the test obligations in `fablepowers:behavioral-testing`).
6. **Self-review the spec** for placeholders, contradictions, ambiguity, and scope creep. Fix before showing.
7. **Builder check** — substantial tier only; small and trivial work skips it. Your self-review can't see the gaps your own context fills in; someone who has only the spec can. Create the design-phase workspace with `bash "<design-spec base dir>/../integration-review/review-package" --init <spec>` (it prints the path, named after the spec), then dispatch a fresh `fablepowers:reviewer` for the **builder check** job with the spec path and the report path `<workspace>/reports/review-builder-check.md`. It reads the spec as the person who will build it and lists what they would still have to guess, each tagged *changes what gets built* or *minor*. Then:
   - Answer what the conversation or the project already settles, and put the answer in the spec.
   - Make the minor calls yourself; each goes under "Decisions I made" in the brief.
   - Bring the build-changing questions to the user as **one** question round, most important first — the only round the check produces.
   - Rule on each item in the check's **Declined to judge** list: settle it in the spec, make the call, or add it to the question round. Each call you make goes under "Decisions I made".

   Update the spec with the answers, commit it, then go to step 8. If the check comes back with nothing build-changing, go straight to step 8.
8. **Approval checkpoint — BLOCKING.** Do not invoke `fablepowers:implementation-plan`, write code, or take any implementation action in the same turn as writing the spec. The approval turn has two parts, in this order, in the same turn:

   **(a) The brief**, in your message, immediately before the ask. Write it for someone reading on a phone who may not open the spec. Link the spec file path once, before the brief. Then six headings, in order:

   - **What changes** — 3 to 7 bullets describing the result as the user will experience it.
   - **Decisions I made** — choices the user did not explicitly ask for, each with a one-clause reason. Include anything that goes against the request or a prior review.
   - **Not doing** — what is out of scope.
   - **Risk** — one line: blast radius and what could break.
   - **Open the spec if** — one line on when the full document is worth reading (for example, if a listed decision matters to you). This is how the user decides to trust the brief instead of reading the spec.
   - **Verified by** — one line on how the spec's success criteria will be tested.

   Then one closing line saying how to approve, with your harness's approve command (see the harness reference): on Claude Code, OpenCode and Pi, answer **Approve** or run `/fablepowers:approve`; on Codex, reply `$fablepowers:approve`.

   Limits: at most 20 words per bullet; no tables; no file paths, identifiers, or code inside the brief, except the approve command in the closing line.

   **(b) The ask**: its own structured question to the user — the harness's question tool (on Pi, `fablepowers_ask_approval`), in a separate call after the brief (a harness with no blocking question, such as Codex, asks in plain text and ends the turn; see the harness reference) — with exactly one question of at most 20 words and exactly two options, **Approve** and **Changes needed**. An approval with a note is Changes needed plus the note, or the user's free-text answer. If the user approves in free text or in chat instead of picking Approve or running the command, ask them to run the approve command: the gate records only those paths, so implementation stays blocked until they do. Changes needed keeps the design pending, so the gate still blocks implementation. After Changes needed, fold the note into the spec and repeat step 8 in full — a fresh brief and a fresh ask — before any implementation; if the note itself says to go ahead unchanged, do not proceed on it: the design is still pending, so ask the user to run the approve command (or re-ask, and they answer **Approve** where the harness has the question). Design variants never appear as approval options; an open variant is a design question, asked in an earlier round. Then **wait**. If the user abandons the design instead, it stays pending until they run the withdraw command (`/fablepowers:withdraw` on Claude Code, OpenCode and Pi, `$fablepowers:withdraw` on Codex); tell them so. Only the user's answer or command records approval — never write or remove the gate's markers yourself.

   Example, for a dismissible banner when a scan fails in a trading-scanner web app:

   ```markdown
   Spec: [scan-failure banner](docs/specs/2026-05-02-scan-failure-banner.md)

   **What changes**
   - When a scan fails, a red banner above the results says which scan failed and why.
   - The banner has a close button; it comes back only on the next failure.
   - The last good results stay visible underneath, marked as out of date.

   **Decisions I made**
   - A banner, not a popup, so the old results stay readable.
   - One banner at a time; a new failure replaces the old one instead of stacking.

   **Not doing**
   - Automatic retries or email alerts for failed scans.

   **Risk**
   - Display only; worst case the banner fails to show or stays stuck on screen.

   **Open the spec if**
   - You want failures to also pause auto-refresh; I chose not to.

   **Verified by**
   - Tests force a scan failure and check the banner appears, closes, and returns on the next failure.

   Approve by answering Approve below, or run `/fablepowers:approve`.
   ```

   Then the ask: "Approve the scan-failure banner design?" with the options **Approve** and **Changes needed**.

## The approval checkpoint

Don't start implementation before the user has explicitly agreed to the design (at whatever tier above trivial). Four failure modes to name and refuse:

- **Answers to clarifying questions are not approval.** They are inputs to the design; the user hasn't seen the assembled design until you present it.
- **The autonomy directive does not apply here.** "Proceed without asking" governs reversible work the user already requested. Design approval is a decision only the user can make — pausing for it is the correct autonomous behavior, and the harness's momentum pressure is exactly the force this checkpoint exists to resist.
- **An ask without a brief is not a checkpoint.** The user may be on a phone and unable to open the spec; the brief is the deliverable of the approval turn, and the spec file is the appendix. An ask with only a path or a one-line summary asks the user to approve a design they haven't seen.
- **Design variants in the options are not approval.** An option that changes the design ("Approve, but skip X") is a design question. Ask it in an earlier round, fold the answer into the spec, then ask for approval with the two fixed options, **Approve** and **Changes needed**. Picking a variant answers that question; it never approves the design.

Everything else in this skill is technique; this checkpoint and the tier rule are not.
