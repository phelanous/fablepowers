# palette Implementation Plan

**Spec:** docs/specs/demo.md
**Goal:** The `Color` enum, a renderer and a CLI.
**Architecture:** Three modules under `palette/`, one per spec item, each with its own test file.
**Implementer:** implementer
**Max parallel:** 4
**Branch:** `main` (this checkout is the plan worktree).

## File structure

| File | Task | Responsibility |
|---|---|---|
| `palette/colors.py`, `tests/test_colors.py` | T1 | the `Color` enum |
| `palette/render.py`, `tests/test_render.py` | T2 | `render(color)` |
| `palette/cli.py`, `tests/test_cli.py` | T3 | `main(argv)` |

## Parallel safety

- `worktree env` — none needed (the suite uses only python3 stdlib)

## Shared conventions

- **Tests:** stdlib `unittest`. Full suite: `bash tests/run-all.sh`. One file: `python3 -m unittest tests.test_<name>`.
- **Commits:** conventional style (`feat: …`), one commit per task.

## T1: `Color` enum

`palette/colors.py` defines `Color(enum.Enum)` with `RED = "#ff0000"`, `GREEN = "#00ff00"`, `BLUE = "#0000ff"`.

**Test obligations:** `tests/test_colors.py`: the three members and their values; `Color("#00ff00") is Color.GREEN`.

**Depends on:** nothing
**Touches:** none

## T2: `render`

`palette/render.py` defines `render(color: Color) -> str`, returning `f"{color.name.lower()}: {color.value}"`. It uses only the `Color` type from T1.

**Test obligations:** `tests/test_render.py`: `render(Color.RED) == "red: #ff0000"`, and the same for `BLUE`.

**Depends on:** T1 (the `Color` enum)
**Touches:** none

## T3: CLI

`palette/cli.py` defines `main(argv)`: it looks the name up as `Color[argv[0].upper()]`, prints its value and returns 0; an unknown name prints an error to stderr and returns 2. `python3 -m palette.cli <name>` calls it with `sys.argv[1:]`.

**Test obligations:** `tests/test_cli.py`: `main(["red"])` prints `#ff0000` and returns 0; `main(["mauve"])` returns 2.

**Touches:** none

## Review Focus

1. `render` output format is exactly `"<name>: <hex>"`.
