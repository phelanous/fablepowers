# 0.2.x hook fixture

`session-start` and `hooks.json` here are the SessionStart hook exactly as
fablepowers 0.2.1 shipped it (commit 839bb3a): an awk/dirname script exec'd
through its `#!/usr/bin/env bash` shebang. `tests/hooks/test-session-start.sh`
uses them as the byte-for-byte reference for the current hook's output, so the
suite runs in any checkout — shallow clones, squash merges and tarballs
included — without needing that commit. Do not edit them.
