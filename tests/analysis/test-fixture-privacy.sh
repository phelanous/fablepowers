#!/usr/bin/env bash
# Privacy guard over the committed session-log fixtures (tests/analysis/fixtures/).
#
# The fixtures are built from real Codex / OpenCode / Pi logs by
# scripts/sanitize_fixture.py and go into a public repository, so this test
# fails (non-zero exit) on anything that looks like it slipped through:
#   * anywhere in a file's bytes or in a file/directory name: a home path
#     ("/home/", an encoded "--home-" / "-home-" directory), a scratch path
#     ("/tmp/claude-"), the username (the literal one and $USER), $HOME, any
#     email address, the excluded project ("colony"), and the Codex key names
#     creator_*, base_instructions, encrypted_content;
#   * in JSONL records and in every SQL cell (JSON cells parsed): any string
#     longer than 200 characters that is not an allowlisted placeholder, an
#     unparseable line longer than 200 characters, and the keys the sanitiser
#     must drop (Codex aggregated_output / parsed_cmd / stdout / stderr / diff
#     bodies / git, Pi childSessionFile / childSessionDir / thinkingSignature,
#     a Pi write's content, an OpenCode tool state's output / content).
#
# Usage: tests/analysis/test-fixture-privacy.sh [FIXTURES_DIR]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="${1:-$SCRIPT_DIR/fixtures}"
[ -d "$FIXTURES" ] || { echo "FAIL: no fixtures dir at $FIXTURES"; exit 1; }

exec python3 - "$FIXTURES" <<'PY'
import json, os, re, sqlite3, sys

root = sys.argv[1]
user = os.environ.get("USER") or ""
home = os.environ.get("HOME") or ""
deny = [r"/home/", r"--home-", r"(^|[^A-Za-z0-9])-home-", r"/tmp/claude-", r"phelanous",
        r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}", r"colony", r"creator_",
        r"base_instructions", r"encrypted_content"]
if user and user != "root":
    deny.append(re.escape(user))
if home and home not in ("/", "/root"):
    deny.append(re.escape(home))
DENY = re.compile("|".join("(?:%s)" % d for d in deny), re.I)
DROPPED_KEYS = {"aggregated_output", "parsed_cmd", "stdout", "stderr", "unified_diff", "diff", "git",
                "childSessionFile", "childSessionDir", "thinkingSignature", "base_instructions", "encrypted_content",
                "creator_user_id", "creator_account_id", "runtime_workspace_roots"}
ALLOWED_LONG = set()  # placeholders longer than 200 chars (none today)
MAXLEN = 200
problems = []


def bad(where, what):
    problems.append(f"{where}: {what}")


def check_tree(v, where, path=()):
    if isinstance(v, dict):
        for k, x in v.items():
            if k in DROPPED_KEYS:
                bad(where, f"dropped key {k!r} present at {'.'.join(path)}")
            check_tree(x, where, path + (k,))
        # Pi write tool call carrying a body
        if v.get("type") == "toolCall" and v.get("name") == "write" and "content" in (v.get("arguments") or {}):
            bad(where, "Pi write.content present")
        # OpenCode tool state carrying the tool's output
        if v.get("type") == "tool" and isinstance(v.get("state"), dict) and ({"output", "content"} & set(v["state"])):
            bad(where, "OpenCode tool state output/content present")
    elif isinstance(v, list):
        for x in v:
            check_tree(x, where, path)
    elif isinstance(v, str):
        if len(v) > MAXLEN and v not in ALLOWED_LONG:
            bad(where, f"string of {len(v)} chars at {'.'.join(path)}")


for dp, dns, fns in os.walk(root):
    for n in dns + fns:
        rel = os.path.relpath(os.path.join(dp, n), root)
        if DENY.search(rel):
            bad(rel, "denylisted name")
    for fn in fns:
        p = os.path.join(dp, fn)
        rel = os.path.relpath(p, root)
        raw = open(p, "rb").read().decode("utf-8", "replace")
        for m in DENY.finditer(raw):
            bad(rel, f"denylisted content {m.group(0)!r}")
        if fn.endswith(".jsonl"):
            for i, line in enumerate(raw.splitlines(), 1):
                try:
                    o = json.loads(line)
                except ValueError:
                    if len(line) > MAXLEN:
                        bad(f"{rel}:{i}", f"unparseable line of {len(line)} chars")
                    continue
                check_tree(o, f"{rel}:{i}")

sqls = sorted(os.path.join(dp, f) for dp, _, fns in os.walk(root) for f in fns if f.endswith(".sql"))
by_dir = {}
for p in sqls:
    by_dir.setdefault(os.path.dirname(p), []).append(p)
for d, files in by_dir.items():
    db = sqlite3.connect(":memory:")
    try:
        for p in files:
            db.executescript(open(p).read())
    except sqlite3.Error as e:
        bad(os.path.relpath(d, root), f"SQL fixture does not load: {e}")
        continue
    for (t,) in db.execute("select name from sqlite_master where type='table'"):
        cols = [r[1] for r in db.execute(f"pragma table_info({t})")]
        for row in db.execute(f"select * from {t}"):
            for c, v in zip(cols, row):
                if not isinstance(v, str):
                    continue
                where = f"{os.path.relpath(d, root)}:{t}.{c}"
                try:
                    j = json.loads(v)
                except ValueError:
                    j = None
                if isinstance(j, (dict, list)):
                    check_tree(j, where)
                elif len(v) > MAXLEN:
                    bad(where, f"string of {len(v)} chars")

if problems:
    for p in problems[:50]:
        print("FAIL:", p)
    print(f"FAIL: {len(problems)} privacy problem(s) in {root}")
    sys.exit(1)
n = sum(len(f) for _, _, f in os.walk(root))
print(f"PASS: {n} fixture files clean ({len(sqls)} SQL files loaded and scanned)")
PY
