# mathx add/mul Implementation Plan

**Spec:** docs/specs/demo.md
**Goal:** Add `add` and `mul` to `mathx`.
**Architecture:** One module per function under `mathx/`, one test file per module under `tests/`.
**Implementer:** implementer
**Max parallel:** 2
**Branch:** `feat/demo`, merged into `main` when finished (this checkout is the plan worktree).

## File structure

| File | Task | Responsibility |
|---|---|---|
| `mathx/add.py`, `tests/test_add.py` | T1 | `add(a, b)` and its tests |
| `mathx/mul.py`, `tests/test_mul.py` | T2 | `mul(a, b)` and its tests |

## Parallel safety

- `worktree env` — none needed (the suite uses only python3 stdlib)

## Shared conventions

- **Tests:** stdlib `unittest`. Full suite: `bash tests/run-all.sh` (a few seconds). One file: `python3 -m unittest tests.test_<name>`.
- **Commits:** conventional style (`feat: …`), one commit per task.

## T1: `add`

`mathx/add.py` defines `add(a, b)` returning `a + b`.

**Test obligations:** `tests/test_add.py`: `add(2, 3) == 5` and `add(-1, 1) == 0`.

**Depends on:** nothing
**Touches:** none

## T2: `mul`

`mathx/mul.py` defines `mul(a, b)` returning `a * b`.

**Test obligations:** `tests/test_mul.py`: `mul(2, 3) == 6` and `mul(-2, 4) == -8`.

**Depends on:** nothing
**Touches:** none

## Review Focus

1. Each function's docstring says what it returns.
