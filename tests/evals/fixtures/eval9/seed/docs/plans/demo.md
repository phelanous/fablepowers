# slugify Implementation Plan

**Spec:** docs/specs/demo.md
**Goal:** Add `textkit.slug.slugify`.
**Architecture:** One module, `textkit/slug.py`, with unit tests in `tests/test_slug.py`; the existing e2e step covers it end to end.
**Implementer:** implementer
**Max parallel:** 4
**Branch:** `main` (this checkout is the plan worktree).

## File structure

| File | Task | Responsibility |
|---|---|---|
| `textkit/slug.py`, `tests/test_slug.py` | T1 | `slugify` and its unit tests |

## Parallel safety

- `e2e` — serialize (one browser e2e run at a time)
- `worktree env` — none needed (the suite uses only python3 stdlib)

## Shared conventions

- **Tests:** stdlib `unittest`. Unit tests for one file: `python3 -m unittest tests.test_<name>` (under a second). Full suite: `bash tests/run-all.sh`, the unit tests and then the browser e2e step, about 3 minutes in all. Suite budget: 10 minutes.
- **Commits:** conventional style (`feat: …`).

## T1: `slugify`

`textkit/slug.py` defines `slugify(title)` as the spec says.

**Test obligations:** `tests/test_slug.py`: `"Hello, World!"` → `"hello-world"`; `"  A -- B  "` → `"a-b"`; `"x"` → `"x"`; `"!!!"` → `""`. The full suite, e2e included, passes.

**Depends on:** nothing
**Touches:** e2e

## Review Focus

1. Runs of separators collapse to one `-`.
