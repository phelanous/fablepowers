# shout, clamp and pad Implementation Plan

**Spec:** docs/specs/demo.md
**Goal:** Add `shout` and `clamp`, each with a unit test and an e2e check, and `pad`, with a unit test.
**Architecture:** One module per function under `util/`; unit tests under `tests/`; e2e checks under `e2e/`, run by `tests/e2e.sh`.
**Implementer:** implementer
**Max parallel:** 4
**Branch:** `main` (this checkout is the plan worktree).

## File structure

| File | Task | Responsibility |
|---|---|---|
| `util/strings.py`, `tests/test_strings.py`, `e2e/check_strings.py` | T1 | `shout` |
| `util/nums.py`, `tests/test_nums.py`, `e2e/check_nums.py` | T2 | `clamp` |
| `util/pad.py`, `tests/test_pad.py` | T3 | `pad` |

## Parallel safety

- `e2e` — serialize (the e2e step binds the fixed port 4500, so two runs at once collide)
- `worktree env` — none needed (the suite uses only python3 stdlib)
- `pre-commit suite` — `python3 -m unittest discover -s tests -t . -q` (the full suite without the serialized e2e step)

## Shared conventions

- **Tests:** stdlib `unittest`. Full suite: `bash tests/run-all.sh` (unit tests, then `bash tests/e2e.sh`; a few seconds). One unit file: `python3 -m unittest tests.test_<name>`.
- **Commits:** conventional style (`feat: …`), one commit per task.

## T1: `shout`

`util/strings.py` defines `shout(s)` returning `s.upper() + "!"`. `e2e/check_strings.py` asserts `shout("hi") == "HI!"` (same shape as `e2e/check_base.py`).

**Test obligations:** `tests/test_strings.py`: `shout("hi") == "HI!"`, `shout("") == "!"`.

**Depends on:** nothing
**Touches:** e2e

## T2: `clamp`

`util/nums.py` defines `clamp(x, lo, hi)` returning `min(max(x, lo), hi)`. `e2e/check_nums.py` asserts `clamp(5, 0, 3) == 3`.

**Test obligations:** `tests/test_nums.py`: below, inside and above the range, and both bounds.

**Depends on:** nothing
**Touches:** e2e

## T3: `pad`

`util/pad.py` defines `pad(s, n)` returning `s` right-padded with spaces to length `n` (`s` unchanged when it is already at least `n` long). No e2e check.

**Test obligations:** `tests/test_pad.py`: `pad("ab", 4) == "ab  "`, `pad("abcd", 2) == "abcd"`, `pad("", 0) == ""`.

**Depends on:** nothing
**Touches:** none

## Review Focus

1. The e2e checks run one at a time (port 4500).
