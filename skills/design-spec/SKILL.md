---
name: design-spec
description: Use before implementing any new feature, component, or behavior change - collaborative dialogue to turn an idea into an approved spec, scaled to the size of the work.
---

# Design Spec

Turn an idea into a design the user has agreed to, through dialogue — before any implementation.

## Scale to the work

- **Trivial** (rename, config tweak, obvious one-liner): no spec doc. State your understanding in one sentence and proceed unless the user objects.
- **Small** (single-file feature, clear scope): a short design summary in chat, get a nod, go.
- **Substantial** (new subsystem, multi-file, ambiguous requirements): full process below.

Use judgment on which tier applies, with one hard rule: **anything that adds user-visible behavior is never trivial, and a new feature is substantial by default** — downgrade only with a stated reason the user can see. When requirements are ambiguous, that alone promotes it a tier — unexamined assumptions on "simple" work are where rework comes from.

## Process (substantial work)

1. **Explore context first** — relevant files, docs, recent commits. Ground questions in what exists.
2. **Ask clarifying questions in rounds** — one message per round, and let each answer shape the next question; the dialogue is the design tool, not a form to fill. Bundling several questions into one `AskUserQuestion` call is allowed only for independent cosmetic/presentation choices — never for requirements discovery, where the interesting question only becomes visible after the previous answer. For substantial work expect 3–6 rounds; stop when no remaining guess would change the design, not when you've exhausted question categories.
3. **Propose 2–3 approaches** with trade-offs and a recommendation. If one approach is clearly right, say so and present it — don't manufacture alternatives.
4. **Present the design in sections** scaled to complexity; confirm direction as you go.
5. **Write the spec** to `docs/specs/YYYY-MM-DD-<topic>.md` (or the project's convention) and commit it. The spec states: goal, chosen approach, key contracts/behaviors, what's out of scope, and **how we'll know it works** (observable behaviors — these become the test obligations in `fablepowers:behavioral-testing`).
6. **Self-review the spec** for placeholders, contradictions, ambiguity, and scope creep. Fix before showing.
7. **Approval checkpoint — BLOCKING.** Present a compact summary of the design plus the spec file path, ask for explicit approval, and **wait**. Do not invoke `fablepowers:implementation-plan`, write code, or take any implementation action in the same turn as writing the spec. **The approval ask stands alone:** it is its own `AskUserQuestion` with exactly one question, or its own message — never in the same call or message as an open design question. If a design question is still open, ask it first and ask for approval on a later turn.

## The approval checkpoint

Don't start implementation before the user has explicitly agreed to the design (at whatever tier above trivial). Three failure modes to name and refuse:

- **Answers to clarifying questions are not approval.** They are inputs to the design; the user hasn't seen the assembled design until you present it.
- **The autonomy directive does not apply here.** "Proceed without asking" governs reversible work the user already requested. Design approval is a decision only the user can make — pausing for it is the correct autonomous behavior, and the harness's momentum pressure is exactly the force this checkpoint exists to resist.
- **A bundled approval ask is not an approval.** The ask is its own `AskUserQuestion` with exactly one question, or its own message; it never shares a call with an open design question. An answer that picks an option is an answer to that option question, never approval of the design — if a design question remains, ask it first and ask for approval on a later turn.

Everything else in this skill is technique; this checkpoint and the tier rule are not.
