#!/usr/bin/env bash
# codex-hook-trust.sh [plugin@marketplace] [cwd]
#
# Prints a one-run Codex config override that trusts one plugin's hooks:
#
#   codex -c "$(scripts/codex-hook-trust.sh fablepowers@fablepowers)" exec ...
#
# Codex runs a plugin's hooks only once each handler is trusted (interactively in
# `/hooks`). For headless runs and tests this asks `codex app-server` for
# `hooks/list`, keeps the handlers of the given plugin, and prints
# `hooks.state={"<key>"={trusted_hash="<currentHash>"},...}` for `-c`.
# Read-only: it never writes ~/.codex/config.toml, and nothing it prints is
# persisted unless you put it there yourself. The trust it grants covers the
# handlers as listed right now (hooks.json entries), not the scripts they run.
#
# Defaults: plugin fablepowers@fablepowers, cwd $PWD. Needs codex and python3.
# Exit 1 when the app-server fails or the plugin has no hooks listed.
set -euo pipefail
plugin_id="${1:-fablepowers@fablepowers}"
cwd="${2:-$PWD}"
command -v codex >/dev/null 2>&1 || { echo "codex-hook-trust: codex not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "codex-hook-trust: python3 not found on PATH" >&2; exit 1; }
exec python3 -I - "$plugin_id" "$cwd" <<'PY'
import json, subprocess, sys, threading

plugin_id, cwd = sys.argv[1], sys.argv[2]
TIMEOUT = 30

p = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True)
timer = threading.Timer(TIMEOUT, p.kill)  # never hang on a server that stops answering
timer.start()


def send(obj):
    p.stdin.write(json.dumps(obj) + "\n")
    p.stdin.flush()


def recv(req_id):
    for line in p.stdout:
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict) and obj.get("id") == req_id:
            return obj
    return None


try:
    send({"id": 0, "method": "initialize",
          "params": {"clientInfo": {"name": "fablepowers-trust", "version": "0"},
                     "capabilities": {"experimentalApi": True}}})
    recv(0)
    send({"method": "initialized"})
    send({"id": 1, "method": "hooks/list", "params": {"cwds": [cwd]}})
    reply = recv(1)
except (OSError, ValueError) as e:
    reply = None
    print("codex-hook-trust: app-server error: %s" % e, file=sys.stderr)
finally:
    timer.cancel()
    p.terminate()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()

if not reply or "result" not in reply:
    sys.exit("codex-hook-trust: hooks/list failed: %r" % (reply,))
items = []
for entry in reply["result"].get("data", []):
    for hook in entry.get("hooks", []):
        if hook.get("pluginId") == plugin_id:
            items.append('"%s"={trusted_hash="%s"}' % (hook["key"], hook["currentHash"]))
if not items:
    sys.exit("codex-hook-trust: no hooks listed for plugin %s (installed and enabled?)" % plugin_id)
print("hooks.state={" + ",".join(items) + "}")
PY
