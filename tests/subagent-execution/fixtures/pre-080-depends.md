# Live sizing basis Implementation Plan

A plan written before 0.8.0, shaped like the real ones the integration review
found: it has Depends on lines, one in a form the wave grammar rejects, and no
Touches lines or Parallel safety section.

**Spec:** docs/specs/live-sizing-basis.md

## File structure

| File | Task |
|---|---|
| `sizing/basis.py` | Task 1 |
| `sizing/report.py` | Task 2 |

## Task 1 — Basis calculation

**Depends on:** nothing (parallel with Task 2)

Compute the basis.

## Task 2 — Report column

**Depends on:** nothing (parallel with Task 1)

## Task 3 — Wire it up

**Depends on:** Tasks 1, 2
