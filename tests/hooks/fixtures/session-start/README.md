# SessionStart payload fixtures

Real SessionStart stdin payloads, captured verbatim during the Codex port's
Task 0 verification run (2026-10-15):

- `codex-sessionstart-*.json`: Codex 0.162.1 (`codex exec`, `exec resume`,
  the TUI, and the first turn after an app-server compaction). Keys: `cwd`,
  `hook_event_name`, `model`, `permission_mode`, `session_id`, `source`,
  `transcript_path` (`~/.codex/sessions/.../rollout-*.jsonl`).
- `claude-sessionstart-startup.json`: Claude Code (`claude -p --plugin-dir`).
  Keys: `cwd`, `hook_event_name`, `session_id`, `source`, `transcript_path`.

`tests/hooks/test-session-start.sh` feeds them to `hooks/session-start` on
stdin to check harness detection. Do not edit them; add new captures instead.
