---
name: using-git-worktrees
description: Use when starting feature work that needs isolation from current workspace or before executing implementation plans - ensures an isolated workspace exists via native tools or git worktree fallback
---

> Vendored from [superpowers](https://github.com/obra/superpowers) v7.0.0 by Jesse Vincent, MIT licensed; see NOTICE. Cross-references retargeted to fablepowers skills. Adapted: plan-requested worktree counts as consent; submodule guard dropped; worktree location anchored at the project root.

# Using Git Worktrees

## Overview

Ensure work happens in an isolated workspace. Prefer your platform's native worktree tools. Fall back to manual git worktrees only when no native tool is available.

**Core principle:** Detect existing isolation first. Then use native tools. Then fall back to git. Never fight the harness.

**Announce at start:** "I'm using the using-git-worktrees skill to set up an isolated workspace."

## Step 0: Detect Existing Isolation

**Before creating anything, check if you are already in an isolated workspace.**

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
BRANCH=$(git branch --show-current)
MAIN_ROOT=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
# Submodule: git lists the module's git dir there; its checkout is core.worktree
if [ "$MAIN_ROOT" = "$GIT_COMMON" ] && WT=$(git config --get core.worktree); then MAIN_ROOT=$(cd "$GIT_COMMON" && cd "$WT" && pwd -P); fi
# Not a checkout root (bare repo, separate git dir) -> empty
[ -n "$MAIN_ROOT" ] && [ "$(git -C "$MAIN_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$MAIN_ROOT" ] || MAIN_ROOT=""
echo "GIT_DIR=$GIT_DIR"
echo "GIT_COMMON=$GIT_COMMON"
echo "BRANCH=${BRANCH:-<detached>}"
echo "WORKTREE_PATH=$(git rev-parse --show-toplevel)"
echo "MAIN_ROOT=$MAIN_ROOT"
```

Shell variables do not persist between your shell calls; later steps use the **printed** paths as literals.

`MAIN_ROOT` is the project root: the main checkout, taken from the first `worktree` entry of `git worktree list --porcelain`. That entry is right from the main checkout, a subdirectory, or a linked worktree; for a submodule (or a linked worktree of one) git lists the module's git dir instead, so the block resolves the submodule's checkout from `core.worktree`. If it prints empty (bare repo, separate git dir), stop and report instead of guessing a path.

**Submodules need no special case.** Inside a submodule's own checkout, `GIT_DIR` and `GIT_COMMON` are both the superproject's `.git/modules/<name>`, so they are equal and the checkout reads as a normal repo; inside a linked worktree of a submodule they differ, and it correctly reads as already isolated. (Upstream's `git rev-parse --show-superproject-working-tree` guard is dropped: it fires in any checkout the superproject tracks as a submodule path, so a linked worktree of a submodule placed at such a path is misclassified as a normal repo.)

**If `GIT_DIR != GIT_COMMON`:** You are already in a linked worktree. Skip to Step 2 (Project Setup). Do NOT create another worktree.

Report with branch state:
- On a branch: "Already in isolated workspace at `<path>` on branch `<name>`."
- Detached HEAD: "Already in isolated workspace at `<path>` (detached HEAD, externally managed). Branch creation needed at finish time."

**If `GIT_DIR == GIT_COMMON`:** You are in a normal repo checkout.

Has the user already indicated their worktree preference in your instructions? If not, ask for consent before creating a worktree:

> "Would you like me to set up an isolated worktree? It protects your current branch from changes."

Honor any existing declared preference without asking. **A worktree requested by `fablepowers:implementation-plan` (which asks for one for substantial work) is the declared preference:** skip the consent ask. If the user declines consent, work in place and skip to Step 2.

## Step 1: Create Isolated Workspace

**You have two mechanisms. Try them in this order.**

### 1a. Native Worktree Tools (preferred)

The user has asked for an isolated workspace (Step 0 consent). Do you already have a way to create a worktree? It might be a tool with a name like `EnterWorktree`, `WorktreeCreate`, a `/worktree` command, or a `--worktree` flag. If you do, use it and skip to Step 2.

Some native tools may only be used after the user explicitly mentions worktrees (Claude Code's `EnterWorktree` is one). If the only consent you have is a `fablepowers:implementation-plan` request, ask the user once, in one line ("The plan asks for an isolated worktree — OK to create one with `EnterWorktree`?"), then use the tool.

Native tools handle directory placement, branch creation, and cleanup automatically. Using `git worktree add` when you have a native tool creates phantom state your harness can't see or manage. A native tool's worktree (for example Claude Code's `<root>/.claude/worktrees/…`) is host-owned: leave its cleanup to the host's exit tool (e.g. `ExitWorktree`).

Only proceed to Step 1b if you have no native worktree tool available.

### 1b. Git Worktree Fallback

**Only use this if Step 1a does not apply** — you have no native worktree tool available. Create a worktree manually using git. A `fablepowers:implementation-plan` request counts as consent here; no further ask is needed.

#### Directory Selection

`$LOCATION` is always resolved against `MAIN_ROOT` (the printed project root from Step 0), never against the current directory. Follow this priority order. Explicit user preference always beats observed filesystem state.

1. **Check your instructions for a declared worktree directory preference.** If the user has already specified one, use it without asking (a relative path means relative to `MAIN_ROOT`).

2. **Check for an existing project-local worktree directory:**
   ```bash
   MAIN_ROOT='<MAIN_ROOT printed by Step 0>'
   ls -d "$MAIN_ROOT/.worktrees" 2>/dev/null     # Preferred (hidden)
   ls -d "$MAIN_ROOT/worktrees" 2>/dev/null      # Alternative
   ```
   If found, use it. If both exist, `.worktrees` wins.

3. **If there is no other guidance available**, default to `$MAIN_ROOT/.worktrees/`.

**Cleanup ownership:** `fablepowers:finishing-a-development-branch` removes a worktree only when its path is under `$MAIN_ROOT/.worktrees/` or `$MAIN_ROOT/worktrees/`. Every other worktree — Claude Code's `$MAIN_ROOT/.claude/worktrees/…`, any native tool's worktree, and a user-declared location outside those two directories — is host-owned and never auto-cleaned. A declared location elsewhere is allowed; tell the user they will remove it themselves.

#### Safety Verification (directories inside the project)

**MUST verify directory is ignored before creating worktree** (with `MAIN_ROOT` set to the printed literal; the trailing slash matters — without it, a `.worktrees/` pattern reads as not-ignored until the directory exists):

```bash
git -C "$MAIN_ROOT" check-ignore -q .worktrees/ 2>/dev/null || git -C "$MAIN_ROOT" check-ignore -q worktrees/ 2>/dev/null
```

For a declared location inside the project, check that directory (relative to `MAIN_ROOT`, with a trailing slash) instead. A location outside the project needs no check.

**If NOT ignored:** Add to `$MAIN_ROOT/.gitignore`, commit the change, then proceed.

**Why critical:** Prevents accidentally committing worktree contents to repository.

#### Create the Worktree

```bash
# LOCATION: absolute path chosen above, e.g. "$MAIN_ROOT/.worktrees"
path="$LOCATION/$BRANCH_NAME"

git worktree add "$path" -b "$BRANCH_NAME"
cd "$path"
```

**Sandbox fallback:** If `git worktree add` fails with a permission error (sandbox denial), tell the user the sandbox blocked worktree creation and you're working in the current directory instead. Then run setup and baseline tests in place.

## Step 2: Project Setup

Auto-detect and run appropriate setup:

```bash
# Node.js
if [ -f package.json ]; then npm install; fi

# Rust
if [ -f Cargo.toml ]; then cargo build; fi

# Python
if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
if [ -f pyproject.toml ]; then poetry install; fi

# Go
if [ -f go.mod ]; then go mod download; fi
```

## Step 3: Verify Clean Baseline

Run tests to ensure workspace starts clean:

```bash
# Use project-appropriate command
npm test / cargo test / pytest / go test ./...
```

**If tests fail:** Report failures, ask whether to proceed or investigate.

**If tests pass:** Report ready.

### Report

```
Worktree ready at <full-path>
Tests passing (<N> tests, 0 failures)
Ready to implement <feature-name>
```

## Quick Reference

| Situation | Action |
|-----------|--------|
| Already in linked worktree (incl. a submodule's) | Skip creation (Step 0) |
| In a submodule's own checkout | Normal repo — the Step 0 comparison already says so |
| Native worktree tool available | Use it (Step 1a); ask once if it needs an explicit user mention |
| No native tool | Git worktree fallback (Step 1b) |
| Plan requested a worktree | Counts as consent — no Step 0 ask |
| `.worktrees/` exists | Use it (verify ignored) |
| `worktrees/` exists | Use it (verify ignored) |
| Both exist | Use `.worktrees/` |
| Neither exists | Check instruction file, then default `$MAIN_ROOT/.worktrees/` |
| Declared location outside `.worktrees/`/`worktrees/` | Allowed; never auto-cleaned |
| Directory not ignored | Add to .gitignore + commit |
| Permission error on create | Sandbox fallback, work in place |
| Tests fail during baseline | Report failures + ask |
| No package.json/Cargo.toml | Skip dependency install |

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "I'm obviously not in a worktree — no need to check" | Run Step 0. Harness-created isolation fools eyeballing; the detection commands settle it. |
| "I'm in a submodule, so `GIT_DIR != GIT_COMMON` can't be trusted" | It can. A submodule's own checkout has them equal; only a linked worktree (of the submodule or not) has them differ. |
| "`git worktree add` is quicker than hunting for a native tool" | A native tool (e.g. `EnterWorktree`) owns placement, branching, and cleanup. Bypassing it is the #1 mistake — it creates phantom state your harness can't see or manage. |
| "`.worktrees` relative to where I am is fine" | Resolve it under `MAIN_ROOT`. From a subdirectory or another worktree, a relative `.worktrees` lands somewhere finishing will never clean up. |
| "The worktree directory is surely ignored already" | Run `git check-ignore`. An unignored worktree directory commits the whole tree into the repo. |
| "Any directory name works" | Explicit instructions beat an existing project-local directory, which beats the `.worktrees/` default. |
| "The workspace is fresh — baseline tests can wait" | A dirty baseline makes every later failure ambiguous. Run the tests now; proceeding past failures is your human partner's call. |

## Integration

**Called by:**
- `fablepowers:implementation-plan`, which asks for a worktree for substantial work — that request is the declared preference, so Step 0's consent ask is skipped
- Any session that needs isolation before dispatching implementers
- Any skill needing isolated workspace

**Pairs with:**
- **fablepowers:finishing-a-development-branch** - for cleanup after work is complete (project-root `.worktrees/` or `worktrees/` only; everything else is host-owned)
