---
name: approve
description: User-only command (/fablepowers:approve [spec key or path]) - records the user's approval of the pending design so implementation can start. The model cannot invoke it; the approval gate hook records the approval when the user types it.
argument-hint: "[spec key or path]"
disable-model-invocation: true
---

# Approve

On Codex, skip to [On Codex](#on-codex). On Claude Code: the user typed `/fablepowers:approve $ARGUMENTS`. This is the user's own explicit approval of the design. The fablepowers approval gate hook acted on it before this text reached you, and its context message says what it recorded.

- **It recorded an approval for a design:** the design is approved. Tell the user in one line which design, then continue the workflow: write the implementation plan with `fablepowers:implementation-plan` (or, when the approved design already has a plan, execute it).
- **It says nothing was pending:** no design was awaiting approval in this repository, so the gate recorded nothing and is not blocking. Tell the user that in one line. If a design is under discussion in this conversation, the command is still the user's approval of it: continue as above.
- **No context message from the gate:** the hook may be disabled (no `python3`, or `FABLEPOWERS_GATE=off`). Treat the command as the user's approval of the design under discussion, and tell the user the gate did not confirm it.

If several designs were pending and no key was given, the hook stops the command before this text appears and lists the keys; the user reruns it with one.

## On Codex

The user's message was `$fablepowers:approve`, optionally with a key. The approval gate hook read that message before you did, and its context message on this turn (it starts `fablepowers approval gate:`) says what it recorded.

- **It recorded an approval for a design:** the design is approved. Tell the user in one line which design, then continue the workflow as above.
- **It says nothing was pending:** tell the user in one line. If a design is under discussion in this conversation, the command is still the user's approval of it: continue as above.
- **It lists several pending designs, or says no pending design matches the key:** nothing was recorded. Show the user the keys and ask them to resend the command with one; do not continue.
- **No context message from the gate:** do not continue, and do not treat this file as an approval. Codex loads it whenever the skill is read, including by you. Tell the user the gate did not record an approval: the fablepowers hooks may be untrusted (they trust them in `/hooks`) or `python3` may be missing; once fixed, they resend the command. Only if the user says they turned the gate off on purpose (`FABLEPOWERS_GATE=off`) is their own `$fablepowers:approve` message the approval.
