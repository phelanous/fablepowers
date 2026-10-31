# Bigger pages and export batches Implementation Plan

**Spec:** docs/specs/demo.md
**Goal:** List-view pages of 50 and export batches of 100.
**Architecture:** The two features are independent: one changes the list view's page size, the other the exporter's batch size.
**Implementer:** implementer
**Max parallel:** 4
**Branch:** `main` (this checkout is the plan worktree).

## File structure

| File | Task | Responsibility |
|---|---|---|
| `app/list_view.py`, `tests/test_list_view.py` | T1 | pages of 50 |
| `app/export.py`, `tests/test_export.py` | T2 | batches of 100 |

## Parallel safety

- `worktree env` — none needed (the suite uses only python3 stdlib)

## Shared conventions

- **Tests:** stdlib `unittest`. Full suite: `bash tests/run-all.sh` (a few seconds). One file: `python3 -m unittest tests.test_<name>`.
- **Commits:** conventional style (`feat: …`), one commit per task.

## T1: List view pages of 50

`first_page(items)` returns the first 50 items (it returns 10 today).

**Test obligations:** `tests/test_list_view.py`: `first_page(range(1000))` has exactly 50 items, the first being 0; `first_page([1, 2])` is `[1, 2]`.

**Depends on:** nothing
**Touches:** none

## T2: Export batches of 100

`batches(items)` returns lists of 100 items in order, the last possibly shorter (the batches hold 10 today).

**Test obligations:** `tests/test_export.py`: `batches(range(250))` has sizes `[100, 100, 50]` and keeps order; `batches([])` is `[]`.

**Depends on:** nothing
**Touches:** none

## Review Focus

1. Page and batch sizes are exact.
