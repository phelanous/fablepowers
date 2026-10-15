---
name: approve
description: User-only command (/fablepowers:approve [spec key or path]) - records the user's approval of the pending design so implementation can start. The model cannot invoke it; the approval gate hook records the approval when the user types it.
argument-hint: "[spec key or path]"
disable-model-invocation: true
---

# Approve

The user typed `/fablepowers:approve $ARGUMENTS`. This is the user's own explicit approval of the design. The fablepowers approval gate hook acted on it before this text reached you, and its context message says what it recorded.

- **It recorded an approval for a design:** the design is approved. Tell the user in one line which design, then continue the workflow: write the implementation plan with `fablepowers:implementation-plan` (or, when the approved design already has a plan, execute it).
- **It says nothing was pending:** no design was awaiting approval in this repository, so the gate recorded nothing and is not blocking. Tell the user that in one line. If a design is under discussion in this conversation, the command is still the user's approval of it: continue as above.
- **No context message from the gate:** the hook may be disabled (no `python3`, or `FABLEPOWERS_GATE=off`). Treat the command as the user's approval of the design under discussion, and tell the user the gate did not confirm it.

If several designs were pending and no key was given, the hook stops the command before this text appears and lists the keys; the user reruns it with one.
