# Real Pi 1.2.0 payloads

Captured on 2026-10-16 by the Task 0 probe extension of the Pi port plan
(`docs/plans/2026-10-16-pi-port.md`). Pi was `@earendil-works/pi-coding-agent`
1.2.0, running headless with OpenRouter `deepseek/deepseek-v4-flash` (thinking
off) as the parent and `qwen/qwen3.6-flash` (thinking low) as the child. Each
file is one event.

## File shape

`{"event": <the object Pi passed to the handler, or one --mode json stdout line>, "ctx": {...} | null, "probe": {...}?}`

- `ctx` is the handler's `ctx` reduced to `mode`, `hasUI`, `cwd`, `sessionId`,
  `model` (`provider/id`) and `thinking`. It is `null` for `--mode json` stdout
  lines.
- `probe` holds what the probe computed itself; Pi did not send it.
  - `existsBefore` is `fs.existsSync` at `tool_call`, after stripping a leading `@`.
  - `existedAtCall` is the same value looked up by `toolCallId` at `tool_result`.
  - Some files carry a `note`.
- The names follow `<event>-<tool>-<variant>.json`. Events that have no tool use
  `none`.
- Absolute paths are replaced with placeholders:
  - `__CWD__`: the session cwd, which in these runs was also the git toplevel, so `__ROOT__` does not appear.
  - `__PLUGIN__`: the extension package root. No captured payload contained it.
  - `__HOME__`: the home directory. No captured payload contained it.

## Files

| File | Event / source | What it shows |
|---|---|---|
| `tool_call-write-create.json` | `tool_call` write | New `docs/specs/*.md`. The path is cwd-relative, as the model sent it. `input` has `path` and `content`. |
| `tool_call-write-overwrite.json` | `tool_call` write | The path already exists (`existsBefore: true`). |
| `tool_call-write-atprefix.json` | `tool_call` write | The model sent `@docs/plans/…`. Pi's tool strips the `@` and wrote `docs/plans/at-plan.md`. |
| `tool_call-write-absolute.json` | `tool_call` write | An absolute path under the cwd. |
| `tool_call-write-isdir-error.json` | `tool_call` write | The path is a directory, so the tool fails. |
| `tool_call-write-blocked.json` | `tool_call` write | The handler returned `{block:true, reason}`. No `tool_result` event followed. |
| `tool_call-write-rewrite.json` | `tool_call` write | The handler set `event.input.path` to an absolute path, and the tool wrote there. |
| `tool_call-edit-existing.json` | `tool_call` edit | `input` is `{path, edits:[{oldText,newText}]}`. |
| `tool_call-read-relative.json` | `tool_call` read | `input` is `{path, offset, limit}`. Reads carry a `path` too (SF2). |
| `tool_call-fablepowers_dispatch-reviewer.json` | `tool_call` | A custom tool registered with a plain JSON-schema `parameters`. `input` is the validated params. |
| `tool_call-fablepowers_dispatch-implementer.json` | `tool_call` | The same tool, with the implementer seat. |
| `tool_call-subagent-single.json` | `tool_call` subagent | The official example's tool in single mode: `{agent, task}`. |
| `tool_call-subagent-parallel.json` | `tool_call` subagent | Parallel mode: `{tasks:[{agent,task}]}`. There is no top-level `agent`. |
| `tool_call-subagent-chain.json` | `tool_call` subagent | Chain mode: `{chain:[{agent,task}]}`. |
| `tool_result-write-create.json` | `tool_result` write | `content` reads "Successfully wrote to <path as sent>". There is no `details` key. `isError` is false. |
| `tool_result-write-overwrite.json` | `tool_result` write | Identical in shape to a create. Only `existedAtCall` tells the two apart. |
| `tool_result-write-atprefix.json` | `tool_result` write | `input.path` still has the `@`. |
| `tool_result-write-absolute.json` | `tool_result` write | An absolute path. |
| `tool_result-write-isdir-error.json` | `tool_result` write | `isError: true`, `details: {}`, and an EISDIR message. |
| `tool_result-write-rewrite.json` | `tool_result` write | `input.path` is the path the `tool_call` handler rewrote it to. |
| `tool_result-edit-existing.json` | `tool_result` edit | `details: {diff, patch, firstChangedLine}`. |
| `tool_result-read-relative.json` | `tool_result` read | Has `structuredContent` (the text). |
| `tool_result-fablepowers_dispatch-reviewer.json` | `tool_result` | A custom tool result, with the `details` the tool returned. |
| `session_start-none-startup.json` | `session_start` | `{reason:"startup"}`. |
| `session_start-none-reload.json` | `session_start` | `{reason:"reload"}`, emitted after the factory re-ran. |
| `session_shutdown-none-reload.json` | `session_shutdown` | `{reason:"reload"}`, emitted before the factory re-ran. |
| `session_shutdown-none-quit.json` | `session_shutdown` | `{reason:"quit"}` at the normal end of `-p`. SIGTERM and SIGHUP give the same event. |
| `child_json-session-header.json` | child `--mode json` stdout, line 1 | The session header `{type:"session",version,id,timestamp,cwd}`. |
| `child_json-message_end-assistant.json` | child `--mode json` stdout | The assistant `message_end`, carrying `provider`, `model` (id without provider), `thinkingLevel`, `usage.cost.total` and `stopReason`. |
| `json-message_end-custom.json` | `--mode json` stdout | `pi.sendMessage({customType, content, display:true})` from a command shows up as a custom `message_end`. |

Pi also sends `session_shutdown` with reasons `new`, `fork` and `resume`. Those
events carry an extra `targetSessionFile`, and the `session_start` that follows
carries `previousSessionFile`. They aren't captured here because those fields
hold scratch session paths. See `.fablepowers/2026-10-16-pi-port/reports/task-0.md`.
