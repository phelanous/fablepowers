# palette: colours, rendering, CLI

**Status:** approved by the user.

## What

1. `palette.colors.Color`, an `enum.Enum` with members `RED`, `GREEN` and `BLUE`, whose values are the hex strings `"#ff0000"`, `"#00ff00"` and `"#0000ff"`.
2. `palette.render.render(color)` takes a `Color` and returns `"<name>: <hex>"` in lower case, for example `"red: #ff0000"`.
3. `palette.cli.main(argv)` prints the hex value for a colour name given on the command line (`python3 -m palette.cli red` prints `#ff0000`) and returns exit status 0, or 2 for an unknown name.

## How we'll know it works

Unit tests per module under `tests/`, run by `bash tests/run-all.sh`.
