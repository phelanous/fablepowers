# Real OpenCode hook payloads (OpenCode 2.0.29)

Captured on 2026-10-16 by a logging probe plugin (Task 0 of the OpenCode port).
Runs used `opencode run --standalone` and a private `opencode serve` started
with `env -i HOME=… PATH=/usr/bin:/bin` outside the repo, model
`opencode/big-pickle` (seat probes: `opencode/cat-jam-free`). Task 1 builds its
gate fixtures from these; Task 3 feeds them to the fake `ctx`.

## Layout

One JSON per event, named `<hook>-<tool>-<variant>.json`:

```json
{ "_source": { "log": "r1", "kind": "tool.after", "opencode": "2.0.29", "note": "…" },
  "payload": { "ev": { …raw hook event… }, "parentID": null } }
```

- For `permission.evaluate`, `tool.before`/`tool.after`, `session.prompt` and
  `command.execute` records, `payload.ev` (or `payload.input` for commands) is
  the object OpenCode passed to the hook. `payload.parentID` was added by the
  probe from `ctx.session.get({sessionID}).parentID` (null for root sessions).
- `session-get-*` hold `ctx.session.get()` records. `context-*-trimmed` keep
  only the keys, roles and the last 4 messages of the `context` event.
- `setup-*` hold what the plugin saw at `setup(ctx)`; env is trimmed to
  PATH/HOME/cwd, and a non-minimal PATH is redacted.
- Strings longer than 8000 chars were truncated by the probe (none here).

## Placeholders

| Placeholder | Meaning |
|---|---|
| `__ROOT__` | git toplevel of the scratch repo (sessions ran in it or in `__ROOT__/sub`) |
| `__PLUGIN__` | plugin root (directory holding `package.json`) |
| `__CWD__` | directory the private `opencode serve` was launched from (outside the repo) |
| `__HOME__` | the user's home directory |
| `__USER_SHELL_PATH__ …` | the launching shell's PATH (redacted) |

Session, message and call ids are the real ones.

## Files

| File | Hook | Note |
|---|---|---|
| `after-edit-root-modified.json` | `tool.after` |  |
| `after-question-root-approve.json` | `tool.after` | question answered "Approve" through the form API on a private opencode serve |
| `after-question-root-cancelled.json` | `tool.after` | question in non-interactive opencode run: status error |
| `after-read-root.json` | `tool.after` |  |
| `after-skill-root.json` | `tool.after` | plugin-registered skill: content carries "Base directory for this skill: <dir>"; output.directory and metadata.directory too |
| `after-subagent-continuation.json` | `tool.after` | child replied as explore ("FileSearchSpecialist"): the agent argument replaced the child's original agent |
| `after-subagent-root.json` | `tool.after` |  |
| `after-write-child-created.json` | `tool.after` |  |
| `after-write-root-created.json` | `tool.after` | result.output.existed false; model-visible text is result.content[].text |
| `after-write-root-marked.json` | `tool.after.marked` | same write result after the probe mutated every candidate field; only result.content[] markers reached the model (see README) |
| `after-write-root-overwrite.json` | `tool.after` | write over an existing file: existed true |
| `after-write-subdir-root-created.json` | `tool.after` | target absolute under <root>/sub; resource relative to session directory |
| `agent-transform-builtin-build.json` | `agent.builtin.before` | agent draft passed to d.update(id, fn) before the probe pushed external_directory allow |
| `agent-transform-builtin-explore.json` | `agent.builtin.before` | agent draft passed to d.update(id, fn) before the probe pushed external_directory allow |
| `agent-transform-builtin-general.json` | `agent.builtin.before` | agent draft passed to d.update(id, fn) before the probe pushed external_directory allow |
| `agent-transform-builtin-plan.json` | `agent.builtin.before` | agent draft passed to d.update(id, fn) before the probe pushed external_directory allow |
| `agent-transform-new-seat.json` | `agent.seat.after` | d.update(newId, fn) creates the agent; defaults mode primary + default permissions; after the probe set mode/system/model |
| `before-edit-root.json` | `tool.before` |  |
| `before-question-root.json` | `tool.before` |  |
| `before-read-root.json` | `tool.before` |  |
| `before-skill-root.json` | `tool.before` |  |
| `before-subagent-continuation.json` | `tool.before` | input carries sessionID of an existing child plus agent |
| `before-subagent-root.json` | `tool.before` |  |
| `before-subagent-seat.json` | `tool.before` |  |
| `before-write-child.json` | `tool.before` |  |
| `before-write-root-abspath.json` | `tool.before` |  |
| `before-write-root.json` | `tool.before` |  |
| `before-write-subdir-root.json` | `tool.before` |  |
| `command-approve.json` | `command.execute` | POST /api/session/:id/command {"name":"fablepowers:approve","text":"foo bar"}; input has args only, no command name |
| `command-withdraw.json` | `command.execute` | empty args |
| `context-child-trimmed.json` | `session.context` | probe logged keys, roles and the last 4 messages only |
| `context-root-trimmed.json` | `session.context` | probe logged keys, roles and the last 4 messages only |
| `permission-edit-root-modified.json` | `permission.evaluate` | edit tool on an existing file in a root session (status "modified") |
| `permission-external_directory-root.json` | `permission.evaluate` | read of a file under the plugin root from a root session (build agent) |
| `permission-question-root.json` | `permission.evaluate` |  |
| `permission-read-root.json` | `permission.evaluate` |  |
| `permission-skill-root.json` | `permission.evaluate` |  |
| `permission-subagent-continuation.json` | `permission.evaluate` | continuation: subagent call with sessionID of an existing child (originally "general") and agent "explore"; resource is the agent that WILL run (OpenCode switches the child to it) |
| `permission-subagent-root.json` | `permission.evaluate` | root session dispatching agent "general"; resources = [target agent id] |
| `permission-subagent-seat.json` | `permission.evaluate` | dispatch to a plugin-registered subagent |
| `permission-write-child-added.json` | `permission.evaluate` | child session (agent general) writing notes/child.txt: evaluate fires for child sessions; parentID from session.get |
| `permission-write-root-abspath.json` | `permission.evaluate` | tool input path was absolute; resources still relative to the session directory |
| `permission-write-root-added.json` | `permission.evaluate` | write tool creating docs/specs/a.md in a root session (metadata.files[].status "added") |
| `permission-write-subdir-child-added.json` | `permission.evaluate` | child of the subdirectory session; child inherits location.directory <root>/sub |
| `permission-write-subdir-root-added.json` | `permission.evaluate` | root session whose directory is <root>/sub; resources relative to the session directory (file landed in sub/docs/specs/s.md); server launched outside the repo |
| `prompt-child-continuation.json` | `session.prompt` | continued child: no subagent preamble |
| `prompt-child.json` | `session.prompt` | subagent prompt: "You are a subagent spawned by another session.\n" + prompt |
| `prompt-root-approve-separate-args.json` | `session.prompt` | opencode run -s <id> /fablepowers:approve foo (separate argv): no quotes |
| `prompt-root.json` | `session.prompt` | opencode run with a single argv containing spaces: text arrives wrapped in one pair of double quotes |
| `session-get-child-continued.json` | `session.get` | same child after continuation with agent explore: agent switched |
| `session-get-child.json` | `session.get` | child record: parentID + agent |
| `session-get-root.json` | `session.get` | root session record: no parentID, no agent; location.directory absolute |
| `session-get-seat-agent-variant-key.json` | `session.get` | agent.transform a.variant="low" (top-level key) -> ignored, child variant default |
| `session-get-seat-model-variant.json` | `session.get` | agent.transform model {providerID,id,variant:"high"} -> child model variant high |
| `session-get-subdir-child.json` | `session.get` |  |
| `session-get-subdir-root.json` | `session.get` | session created in <root>/sub on a server launched in another directory: subpath "sub" |
| `setup-dedupe-same-id.json` | `setup` | XDG_CONFIG_HOME global config listing [plugin, plugin2-copy] + project config listing plugin: 3 "loading plugin" log lines, both modules imported (globalCount 2), but setup ran ONCE (both default exports share id fp-probe-t0) |
| `setup-serve-minimal-env.json` | `setup` | plugin setup under env -i HOME PATH=/usr/bin:/bin opencode serve launched in __CWD__ |
| `setup-serve-second-location.json` | `setup` | second instance in the same server process for location <root>/sub (globalCount 2) |
| `setup-standalone.json` | `setup` | plugin setup under opencode run --standalone (env trimmed to PATH/HOME/cwd) |
| `synthetic-result.json` | `synthetic.ok` | return value of ctx.session.synthetic(); the model then answered it in a new turn |
