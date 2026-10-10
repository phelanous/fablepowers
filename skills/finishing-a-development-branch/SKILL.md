---
name: finishing-a-development-branch
description: Use when implementation is complete, all tests pass, and you need to decide how to integrate the work - guides completion of development work by presenting structured options for merge, PR, or cleanup
---

> Vendored from [superpowers](https://github.com/obra/superpowers) v7.0.0 by Jesse Vincent, MIT licensed; see NOTICE. Cross-references retargeted to fablepowers skills. Adapted: forge CLIs named (gh/fj/glab); provenance anchored at the project root; Step 2 prints the paths later steps use; the merge runs where the base branch is checked out.

# Finishing a Development Branch

## Overview

**Core principle:** Verify tests → Detect environment → Present options → Execute choice → Clean up.

**Announce at start:** "I'm using the finishing-a-development-branch skill to complete this work."

## Step 1: Verify Tests

Run the project's full test suite (`npm test` / `cargo test` / `pytest` / `go test ./...`)
with `fablepowers:verify-done` semantics: a fresh run on this tree, output read
before you say anything about it.

**If tests fail**, report the failures and stop — the menu comes after a green suite:

```
Tests failing (<N> failures). Must fix before completing:

[Show failures]
```

**If tests pass:** continue to Step 2.

## Step 2: Detect Environment

Run this from inside the workspace, before any `cd`:

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
WORKTREE_PATH=$(cd "$(git rev-parse --show-toplevel)" 2>/dev/null && pwd -P)
# Project root = main checkout = first entry of the worktree list (same
# computation as fablepowers:using-git-worktrees)
MAIN_ROOT=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
# Submodule: git lists the module's git dir there; its checkout is core.worktree
if [ "$MAIN_ROOT" = "$GIT_COMMON" ] && WT=$(git config --get core.worktree); then MAIN_ROOT=$(cd "$GIT_COMMON" && cd "$WT" && pwd -P); fi
# Not a checkout root (bare repo, separate git dir) -> empty
[ -n "$MAIN_ROOT" ] && [ "$(git -C "$MAIN_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$MAIN_ROOT" ] || MAIN_ROOT=""
printf 'GIT_DIR=%s\nGIT_COMMON=%s\nWORKTREE_PATH=%s\nMAIN_ROOT=%s\nBRANCH=%s\n' \
  "$GIT_DIR" "$GIT_COMMON" "$WORKTREE_PATH" "$MAIN_ROOT" "$(git branch --show-current)"
[ -n "$MAIN_ROOT" ] || echo "MAIN_ROOT is empty - Option 1 and discard unavailable; worktree is host-owned"
```

**Shell variables do not survive between your shell calls; the working
directory does.** Note the printed values. Every later step uses those
printed literal paths — write them into the command in place of
`<WORKTREE_PATH>`, `<MAIN_ROOT>`, etc. Never re-derive them after a `cd`:
from the main checkout, `git rev-parse` describes the main checkout, not the
worktree you are finishing. If `MAIN_ROOT` printed empty (bare repo,
separate git dir), only the steps that use it are blocked: Option 1 and
discard stop and report, and Step 6 treats the worktree as host-owned.
Options 2 and 3 never use `MAIN_ROOT` and proceed normally. Never `cd ""`.

The printed values determine which menu to show and how cleanup works:

| State | Menu | Cleanup |
|-------|------|---------|
| `GIT_DIR == GIT_COMMON` (normal repo) | Standard 3 options | No worktree to clean up |
| `GIT_DIR != GIT_COMMON`, named branch | Standard 3 options | Provenance-based (see Step 6) |
| `GIT_DIR != GIT_COMMON`, detached HEAD (empty `BRANCH`) | Reduced 2 options (no merge) | Provenance-based (see Step 6) — reached only on a confirmed discard |

(The `GIT_DIR`/`GIT_COMMON` comparison is also correct inside a submodule:
its checkout reports the same directory for both; a linked worktree of it
does not.)

`MAIN_ROOT` is the project root that cleanup ownership (Step 6) is anchored
to, and where the merge falls back to when the base branch is not checked
out anywhere.

## Step 3: Determine Base Branch

The base branch is whatever this work forked from — usually named in the
plan, the conversation, or the branch's upstream. If it is not already
known, ask: "This branch split from <your best guess> - is that correct?"
Confirm before merging: merging into the wrong base is expensive to undo.

Once the base is confirmed, find where it is checked out (any directory of
the repo works; still no `cd` needed):

```bash
BASE=<base-branch>
BASE_WORKTREE=$(git worktree list --porcelain | awk -v ref="branch refs/heads/$BASE" '/^worktree /{p=substr($0,10)} $0==ref{print p}')
printf 'BASE_WORKTREE=%s\n' "$BASE_WORKTREE"
```

Empty means `<base-branch>` is not checked out in any worktree. Use the
printed value as `<BASE_WORKTREE>` below.

## Step 4: Present Options

**Normal repo and named-branch worktree — present exactly these 3 options:**

```
Implementation complete. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (I'll handle it later)

Which option?
```

**Detached HEAD — present exactly these 2 options:**

```
Implementation complete. You're on a detached HEAD (externally managed workspace).

1. Push as new branch and create a Pull Request
2. Keep as-is (I'll handle it later)

Which option?
```

Present the menu exactly as written — concise, with every option coming
from the list above. Discarding the work happens only in response to your
human partner explicitly asking for it (see "If your human partner asks to
discard the work" below). Wait for their answer; the integration decision
is theirs.

## Step 5: Execute Choice

### Option 1: Merge Locally

If `MAIN_ROOT` printed empty, stop and report: there is no project root to
merge from or anchor cleanup to.

The merge runs in the worktree where `<base-branch>` is checked out — never
`git checkout <base-branch>` from inside the feature worktree (git refuses
while the base is checked out elsewhere, and it would strand the feature
worktree on the wrong branch).

- **`<BASE_WORKTREE>` printed a path:** merge there. If `git status
  --porcelain` there shows uncommitted changes, ask before merging into them.
- **`<BASE_WORKTREE>` printed empty:** check `<base-branch>` out in
  `<MAIN_ROOT>` only if `git -C "<MAIN_ROOT>" status --porcelain` prints
  nothing and `<MAIN_ROOT>` is not on some other in-progress branch (in a
  normal repo it is on the feature branch itself, which is fine). Otherwise
  ask your human partner where to merge.

```bash
cd "<BASE_WORKTREE>"   # or "<MAIN_ROOT>" when BASE_WORKTREE was empty
# git checkout <base-branch>   # only when BASE_WORKTREE was empty
git pull                       # skip if <base-branch> has no upstream
git merge <feature-branch>

# Verify tests on merged result
<test command>
```

If tests fail on the merged result: stop, leave the worktree and branch in
place, and investigate — nothing has been pushed, so the merge is local
and recoverable.

Once the merged result is green: clean up the worktree (Step 6), then,
if Step 6 removed it or there was none (normal repo), delete the branch:

```bash
git branch -d <feature-branch>
```

If Step 6 left a host-owned worktree in place, the branch is still checked
out there and `git branch -d` would fail. Skip it and report: "Branch
<feature-branch> stays checked out in the host-owned worktree <WORKTREE_PATH>."

### Option 2: Push and Create PR

```bash
git push -u origin <feature-branch>
# From a detached HEAD, name the new branch on the remote:
# git push origin HEAD:refs/heads/<new-branch>
git remote get-url origin
```

Then create the pull/merge request against `<base-branch>` with the CLI for
the remote's forge. User instructions naming a forge or CLI win; otherwise
pick by the remote's host:

| Forge | Auth check | Create |
|-------|-----------|--------|
| GitHub | `gh auth status` | `gh pr create --base <base-branch> --head <branch> --title "<title>" --body-file <body.md>` |
| Forgejo / Gitea family (incl. Codeberg) | `fj whoami` | `fj pr create "<title>" --base <base-branch> --head <branch> --body-file <body.md>` |
| GitLab | `glab auth status` | `glab mr create --target-branch <base-branch> --source-branch <branch> --title "<title>" --description-file <body.md> --yes` |

- Run the auth check first; the CLI must be installed and authenticated for
  the remote's host. `fj whoami` must name the forge host with no port — a
  `host:port` means the remote URL carries the SSH port and `fj` will speak
  HTTPS to it; report that instead of proceeding.
- Write the body to a file first (outside the repo). Follow the repo's
  PR/MR template and conventions if present. Each command above is fully
  non-interactive: title and body file given, plus `--yes` for glab — do not
  drop those flags, or the CLI opens an editor or prompt.
- For a host the table does not name (self-hosted Forgejo, Gitea or
  GitLab), probe with the auth checks — `fj whoami --host <host>` and
  `glab auth status --hostname <host>` — and treat whichever authenticates
  for that host as the forge.
- If no matching CLI is installed and authenticated, use the creation URL
  the forge printed on push.
- Report the PR/MR URL to your human partner.

Keep the worktree — your human partner iterates on PR feedback there.

### Option 3: Keep As-Is

Report: "Keeping branch <name>. Worktree preserved at <path>."

### If your human partner asks to discard the work

This path exists only as a response to an explicit request to throw the
work away. If `MAIN_ROOT` printed empty, stop and report — there is no
project root to leave the worktree for. Otherwise confirm first:

```
This will permanently delete:
- Branch <name>
- All commits: <commit-list>
- Worktree at <path>

Type 'discard' to confirm.
```

Wait for that exact confirmation. When it arrives:

```bash
cd "<MAIN_ROOT>"
```

Then clean up the worktree (Step 6) and, if it was removed or there was
none, force-delete the branch (from a normal repo, first check out
`<base-branch>` in `<MAIN_ROOT>`):

```bash
git branch -D <feature-branch>
```

## Step 6: Cleanup Workspace

**Runs for Option 1 and confirmed discards.** Options 2 and 3 always
preserve the worktree. Both callers have already changed directory out of
the worktree — removal must run from outside it — and use the printed Step 2
values, from before that directory change.

**If `GIT_DIR == GIT_COMMON`:** Normal repo, no worktree to clean up. Done.

**If `MAIN_ROOT` printed empty:** host-owned — leave it in place (see
below).

**Ownership is anchored at the project root.** This skill removes a worktree
only when its path is under `<MAIN_ROOT>/.worktrees/` or
`<MAIN_ROOT>/worktrees/` (where `fablepowers:using-git-worktrees` creates
them). Every other worktree — Claude Code's `<MAIN_ROOT>/.claude/worktrees/…`,
any native tool's worktree, and a user-declared location outside those two
directories — is host-owned and never auto-cleaned. Check with the printed
values:

```bash
WORKTREE_PATH='<WORKTREE_PATH>'; MAIN_ROOT='<MAIN_ROOT>'
case "$WORKTREE_PATH" in
  "$MAIN_ROOT"/.worktrees/?*|"$MAIN_ROOT"/worktrees/?*) echo owned ;;
  *) echo host-owned ;;
esac
```

**Owned:** we own cleanup:

```bash
git worktree remove "<WORKTREE_PATH>"
git worktree prune  # Self-healing: clean up any stale registrations
```

**If removal is refused** (`contains modified or untracked files`): the
worktree holds files that exist nowhere else — uncommitted plans, notes,
or scratch work. Never `--force` on your own initiative. Show your human
partner what is at stake and ask:

```bash
git -C "<WORKTREE_PATH>" status --porcelain -uall
```

```
Worktree removal refused — these files were never committed:

<file list>

1. Commit them to <branch> before cleanup
2. Move them into <main repo root>
3. Delete them (unrecoverable)

Which?
```

Carry out the choice, then remove the worktree.

**Host-owned:** never `git worktree remove` it — leave it in place. The
branch stays checked out there, so skip the branch deletion and report
"Branch <name> stays checked out in the host-owned worktree <WORKTREE_PATH>."
If the harness's workspace-exit tool created this worktree in this session
(Claude Code `ExitWorktree`), you may offer it: action **keep** by default;
**remove** (deletes the worktree *and* its branch) only when your human
partner explicitly asks — a confirmed discard counts — and never after
Option 2 or 3, since the PR or kept work needs the branch. If the tool is not
usable for this worktree, leave everything and say so.

## Quick Reference

| Option | Merge | Push | Keep Worktree | Cleanup Branch |
|--------|-------|------|---------------|----------------|
| 1. Merge locally | yes | - | owned: no; host-owned: yes | owned: yes; host-owned: no (reported) |
| 2. Create PR | - | yes | yes | - |
| 3. Keep as-is | - | - | yes | - |
| Discard (explicit request only) | - | - | owned: no; host-owned: yes | owned: yes (force); host-owned: no (reported) |

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "Tests passed earlier this session" | Run the suite on the tree you are about to integrate. A green run only proves the tree it ran on. |
| "They obviously want it merged" | Integration is your human partner's decision. Present the menu and wait. |
| "They seem done with this feature — I'll offer to discard it" | The menu is complete as written. Discard happens only when your human partner asks for it in so many words. |
| "'Yeah, get rid of it' counts as confirmation" | Only the typed word `discard` authorizes deletion. |
| "The PR is up, so the worktree is clutter now" | PR feedback gets fixed in that worktree. It stays until the work lands. |
| "This other worktree looks stale — I'll clean it too" | Clean up only worktrees under `<MAIN_ROOT>/.worktrees/` or `<MAIN_ROOT>/worktrees/`. Everything else — `.claude/worktrees/`, custom locations — belongs to the host. |
| "It's under some `worktrees/` directory, so it's ours" | Only the project root's `.worktrees/` and `worktrees/` count. `.claude/worktrees/` is Claude Code's. |
| "I'll just `git checkout main` here and merge" | Merge where the base is checked out (`BASE_WORKTREE`), never from inside the feature worktree. |
| "Removal refused — `--force` is just finishing the cleanup" | The refusal means files exist only in that worktree. `--force` destroys them permanently. Show your human partner and ask. |
| "The merged-result failure is probably flaky" | A failing merged result stops everything. Branch and worktree stay put while you investigate. |
| "The base branch is obviously main" | Confirm the fork point or ask. Merging into the wrong base is expensive to undo. |
| "The push was rejected — force-push will fix it" | A rejected push means the remote moved. Investigate; force-push only on your human partner's explicit request. |

## Integration

**Called by:**
- Called after `fablepowers:integration-review` passes and `fablepowers:verify-done` has run

**Pairs with:**
- **fablepowers:using-git-worktrees** - Cleans up worktrees that skill created under the project root's `.worktrees/` or `worktrees/`
