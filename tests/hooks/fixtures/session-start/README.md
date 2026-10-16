# SessionStart payload fixtures

Real SessionStart stdin payloads, captured verbatim during the Codex port's
Task 0 verification run (2026-10-15), and later Claude Code captures:

- `codex-sessionstart-*.json`: Codex 0.162.1 (`codex exec`, `exec resume`,
  the TUI, and the first turn after an app-server compaction). Keys: `cwd`,
  `hook_event_name`, `model`, `permission_mode`, `session_id`, `source`,
  `transcript_path` (`~/.codex/sessions/.../rollout-*.jsonl`).
- `claude-sessionstart-startup.json`: Claude Code (`claude -p --plugin-dir`).
  Keys: `cwd`, `hook_event_name`, `session_id`, `source`, `transcript_path`.
- `claude-sessionstart-resume.json`, `claude-sessionstart-compact.json`: Claude
  Code 2.1.299, captured in the 0.5.0 integration fix round (`claude -p
  --plugin-dir`, then `claude -p --resume <id> /compact`, haiku). The resume
  payload adds `scratchpad_dir` and cache fields; the compact one adds
  `prompt_id` and `model` (`claude-haiku-5-5`), so `model` is not Codex-only.
  `transcript_path` is `~/.claude/projects/<project>/<uuid>.jsonl`.

`tests/hooks/test-session-start.sh` feeds them to `hooks/session-start` on
stdin to check harness detection. Do not edit them; add new captures instead.

Hand-written models.toml fixtures (not captures):

- `models-full.toml`: every `[codex]` key set, plus other tables to ignore.
- `models-both.toml`: a `[codex]` and an `[opencode]` table side by side, for
  the no-cross-warnings checks in both modes.
