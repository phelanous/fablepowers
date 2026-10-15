---
name: withdraw
description: User-only command (/fablepowers:withdraw [spec key or path]) - withdraws a pending design the user has abandoned, so the approval gate stops blocking. The model cannot invoke it; the approval gate hook clears the pending marker when the user types it.
argument-hint: "[spec key or path]"
disable-model-invocation: true
---

# Withdraw

The user typed `/fablepowers:withdraw $ARGUMENTS`. The fablepowers approval gate hook acted on it before this text reached you, and its context message says which design it withdrew (or that nothing was pending).

A withdrawn design is abandoned, not approved. Stop all work on it: do not write its plan or start its implementation. Tell the user in one line what was withdrawn, then ask what they want to do next. The spec file stays where it is; deleting it is the user's call.

If several designs were pending and no key was given, the hook stops the command before this text appears and lists the keys; the user reruns it with one.
