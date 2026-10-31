# Plan whose fence is left open and pairs with a later block's closer

The shape the re-review found (R2): T1's interface note opens a fence and
forgets to close it. ```bash in T3 can't close it (a closer has no info
string), but that block's closing ``` does, so T1's Depends on line, all of
T2 and T3's heading sit inside one fence.

## Parallel safety

None.

## T1: Types

An interface note:

```python
def parse(text): ...

**Depends on:** nothing
**Touches:** none

## T2: Parser

**Depends on:** T1
**Touches:** none

## T3: CLI

```bash
python3 -m cli
```

**Depends on:** nothing
**Touches:** none
