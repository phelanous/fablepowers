#!/usr/bin/env node
// A fake `pi --mode json -p ...` for the fablepowers_dispatch tests (MF2). It prints
// the lines a real Pi 1.2.0 child prints (shapes from tests/pi/fixtures/child_json-*):
// the session header, a system message_end, then the assistant message_end, and
// writes a session file `<ts>_<id>.jsonl` into --session-dir.
//
// FAKE_PI_MODE selects the variant:
//   normal       final text FAKE_PI_TEXT (default "fake child done")
//   echo         final text = JSON {argv, env, cwd, prompt, taskFile}; a string over
//                2,000 chars is summarised as {length, head, tail} (the output cap)
//   big          final text of 60 KiB
//   fail         stderr text, an assistant turn with stopReason "error", exit 3
//   hang         header only, then waits forever
//   ignore-term  as hang, and ignores SIGTERM
// FAKE_PI_MODEL / FAKE_PI_THINKING override the reported model ("provider/id") and
// thinking level (default: the --model / --thinking arguments). FAKE_PI_PIDFILE:
// the pid is written there once the header is out.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const argv = process.argv.slice(2);
const mode = process.env.FAKE_PI_MODE || 'normal';
const arg = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
const out = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);

const id = crypto.randomUUID();
const ts = new Date().toISOString();
out({ type: 'session', version: 3, id, timestamp: ts, cwd: process.cwd() });
const sessionDir = arg('--session-dir');
if (sessionDir) {
  fs.mkdirSync(sessionDir, { recursive: true });
  fs.writeFileSync(path.join(sessionDir, `${ts.replace(/[:.]/g, '-')}_${id}.jsonl`),
    `${JSON.stringify({ type: 'session', version: 3, id, timestamp: ts, cwd: process.cwd() })}\n`);
}
if (process.env.FAKE_PI_PIDFILE) fs.writeFileSync(process.env.FAKE_PI_PIDFILE, String(process.pid));

if (mode === 'hang' || mode === 'ignore-term') {
  if (mode === 'ignore-term') process.on('SIGTERM', () => { /* ignored */ });
  setInterval(() => {}, 1000);
} else {
  out({ type: 'message_end', message: { role: 'system', content: [{ type: 'text', text: 'system' }] } });
  const model = process.env.FAKE_PI_MODEL || arg('--model') || 'fake/default-model';
  const slash = model.indexOf('/');
  const thinking = process.env.FAKE_PI_THINKING || arg('--thinking') || 'medium';
  let text = process.env.FAKE_PI_TEXT || 'fake child done';
  let stopReason = 'stop';
  let errorMessage;
  if (mode === 'echo') {
    const prompt = arg('--append-system-prompt');
    const last = argv[argv.length - 1] || '';
    const m = /^Task: read (\S+) and/.exec(last);
    const env = {};
    for (const [k, v] of Object.entries(process.env)) if (k.startsWith('FABLEPOWERS_') || k === 'PI_SESSION_ID') env[k] = v;
    const short = (v) => (typeof v === 'string' && v.length > 2000 ? { length: v.length, head: v.slice(0, 40), tail: v.slice(-40) } : v);
    text = JSON.stringify({
      argv: argv.map(short), env, cwd: process.cwd(),
      prompt: prompt && fs.existsSync(prompt) ? fs.readFileSync(prompt, 'utf8') : null,
      taskFile: m && fs.existsSync(m[1]) ? short(fs.readFileSync(m[1], 'utf8')) : null,
    });
  } else if (mode === 'big') {
    text = `BIG-START${'x'.repeat(60 * 1024)}BIG-END`;
  } else if (mode === 'fail') {
    process.stderr.write('fake child: provider exploded\n');
    stopReason = 'error';
    errorMessage = 'provider exploded';
    text = '';
  }
  out({
    type: 'message_end',
    message: {
      role: 'assistant', content: text ? [{ type: 'text', text }] : [],
      provider: model.slice(0, slash), model: model.slice(slash + 1), thinkingLevel: thinking,
      usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 15, cost: { total: 0.001 } },
      stopReason, ...(errorMessage ? { errorMessage } : {}),
    },
  });
  process.exitCode = mode === 'fail' ? 3 : 0;
}
