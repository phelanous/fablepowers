// Tests for the Pi extension (pi/fablepowers.ts), run with `node --test` and its
// TypeScript type stripping (tests/pi/run.sh). A fake `pi` API object models the
// parts of Pi 1.2.0's ExtensionAPI the extension uses (on, registerTool,
// registerCommand, registerFlag, getFlag, sendMessage, appendEntry); events and
// ctx follow the real payloads under tests/pi/fixtures/. Integration tests run the
// REAL hooks/approval_gate.py and hooks/session-start --pi against temp git repos.
// Dispatch runs a real fake-`pi` process (tests/pi/fake-pi.mjs) through the
// injectable piInvocation (MF2); the default invocation is never used here.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const FIX = path.join(HERE, 'fixtures');
const FAKE_PI = path.join(HERE, 'fake-pi.mjs');
const { createExtension } = await import(pathToFileURL(path.join(ROOT, 'pi', 'fablepowers.ts')).href);
const { GUARD, SECTION, RESULT_TYPE, OUTPUT_CAP, resolveToCwd, piInvocationFor, findPython, capOutput } = createExtension.internals;

const TMP = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fp-pi-test-')));
process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }));
process.chdir(TMP); // the duplicate-copy log goes to process.cwd(): keep it out of the repo
let n = 0;
const tmpdir = (name) => { const d = path.join(TMP, `${name}-${++n}`); fs.mkdirSync(d, { recursive: true }); return d; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const BASE_ENV = { ...process.env };
for (const k of ['FABLEPOWERS_GATE', 'FABLEPOWERS_PYTHON', 'FABLEPOWERS_BASH', 'XDG_CONFIG_HOME', 'PI_SESSION_ID',
  'PI_CODING_AGENT_DIR', 'FABLEPOWERS_PARENT_SESSION', 'FABLEPOWERS_SEAT', 'FABLEPOWERS_PARENT_PID']) delete BASE_ENV[k];
BASE_ENV.GIT_CONFIG_GLOBAL = '/dev/null';
BASE_ENV.GIT_CONFIG_NOSYSTEM = '1';
const REAL_PYTHON = findPython(BASE_ENV);
const PINNED = '[pi]\nimplementer = "openrouter/qwen/qwen3.6-flash"\nimplementer_thinking = "low"\nreviewer = "openrouter/deepseek/deepseek-v4-flash"\n';

function home(models) {
  const h = tmpdir('home');
  if (models !== undefined) {
    fs.mkdirSync(path.join(h, '.config', 'fablepowers'), { recursive: true });
    fs.writeFileSync(path.join(h, '.config', 'fablepowers', 'models.toml'), models);
  }
  return h;
}
const envWith = (extra = {}, models) => ({ ...BASE_ENV, HOME: home(models), ...extra });

function newRepo() {
  const r = tmpdir('repo');
  spawnSync('git', ['init', '-q', r]);
  for (const d of ['docs/specs', 'docs/plans', 'src']) fs.mkdirSync(path.join(r, d), { recursive: true });
  fs.writeFileSync(path.join(r, 'src', 'app.py'), 'x = 1\n');
  return r;
}

function fixture(name) {
  return JSON.parse(fs.readFileSync(path.join(FIX, `${name}.json`), 'utf8'));
}

// A fake Pi ExtensionAPI. flags: values getFlag returns (Pi applies CLI flag
// values after the factory ran, so tests set them before emitting session_start).
function fakePi(flags = {}) {
  const handlers = {};
  const tools = new Map();
  const commands = new Map();
  const flagDefs = new Map();
  const sent = [];
  const entries = [];
  const pi = {
    handlers, tools, commands, flagDefs, sent, entries, flagValues: { ...flags },
    on(ev, fn) { (handlers[ev] ||= []).push(fn); return () => {}; },
    registerTool(t) { if (tools.has(t.name)) throw new Error(`Tool "${t.name}" conflicts`); tools.set(t.name, t); },
    registerCommand(name, opts) { commands.set(name, opts); },
    registerFlag(name, opts) { flagDefs.set(name, opts); },
    getFlag(name) { return name in pi.flagValues ? pi.flagValues[name] : flagDefs.get(name)?.default; },
    sendMessage(m, o) { sent.push({ m, o }); },
    appendEntry(type, data) { entries.push({ type, data }); },
    getThinkingLevel() { return 'medium'; },
    async emit(ev, event, ctx) {
      let r;
      for (const h of handlers[ev] || []) { const x = await h(event, ctx); if (x !== undefined) r = x; }
      return r;
    },
  };
  return pi;
}

function fakeCtx({ cwd, mode = 'print', hasUI, select, sessionId = 'sess-parent-1', sessionFile, sessionDir,
  model = { provider: 'prov', id: 'session-model' }, thinkingLevel = 'high' } = {}) {
  const ctx = {
    cwd, mode, hasUI: hasUI ?? (mode === 'tui' || mode === 'rpc'), model, thinkingLevel,
    notes: [], selects: [], aborts: 0, shutdowns: 0,
    sessionManager: {
      getSessionId: () => sessionId,
      getSessionFile: () => sessionFile,
      getSessionDir: () => sessionDir,
    },
    ui: {
      notify: (t, k) => ctx.notes.push({ t, k }),
      select: async (title, options) => { ctx.selects.push({ title, options }); return select ? select(title, options) : undefined; },
    },
    abort() { ctx.aborts++; },
    shutdown() { ctx.shutdowns++; },
  };
  return ctx;
}

function stderrSink() { const lines = []; return { lines, write: (s) => { lines.push(String(s)); return true; } }; }

const invocation = (args) => ({ command: process.execPath, args: [FAKE_PI, ...args] });

// load(): a fresh extension generation in a fresh fake pi (the global guard cleared first).
function load({ env = envWith(), flags = {}, ...opts } = {}) {
  delete globalThis[GUARD];
  const pi = fakePi(flags);
  const err = stderrSink();
  createExtension({ root: ROOT, env, piInvocation: invocation, tmpdir: tmpdir('t'), stderr: err, ...opts })(pi);
  pi.stderr = err;
  return pi;
}

const gateLog = (repo) => { try { return fs.readFileSync(path.join(repo, '.fablepowers', 'gate.log'), 'utf8'); } catch { return ''; } };
const pendingMarker = (repo, key) => path.join(repo, '.fablepowers', key, 'pending');
const approvedMarker = (repo, key) => path.join(repo, '.fablepowers', key, 'approved');
const readJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
let callN = 0;

// write(pi, ctx, p): tool_call for a write of `p`; returns {block, event}.
async function write(pi, ctx, p, tool = 'write') {
  const event = { type: 'tool_call', toolName: tool, toolCallId: `call-${++callN}`, input: tool === 'write' ? { path: p, content: '# x\n' } : { path: p, edits: [{ oldText: 'a', newText: 'b' }] } };
  const block = await pi.emit('tool_call', event, ctx);
  return { block, event };
}

// createSpec(pi, ctx, repo, rel): tool_call (file absent), the file written, tool_result.
async function createSpec(pi, ctx, repo, rel) {
  const { block, event } = await write(pi, ctx, rel);
  assert.equal(block, undefined);
  fs.mkdirSync(path.dirname(event.input.path), { recursive: true });
  fs.writeFileSync(event.input.path, '# spec\n');
  return pi.emit('tool_result', {
    type: 'tool_result', toolName: 'write', toolCallId: event.toolCallId, input: event.input,
    content: [{ type: 'text', text: `Successfully wrote to ${rel}` }], isError: false,
  }, ctx);
}

const skip = REAL_PYTHON ? false : 'python3 3.8+ not found';

// --- registration and the load-once guard (MF1, Task 0 item 9) ---------------------------

test('registers the flag, both tools (dispatch sequential), both commands and the handlers', () => {
  const pi = load();
  assert.deepEqual([...pi.tools.keys()].sort(), ['fablepowers_ask_approval', 'fablepowers_dispatch']);
  assert.equal(pi.tools.get('fablepowers_dispatch').executionMode, 'sequential');
  assert.deepEqual(pi.tools.get('fablepowers_dispatch').parameters.required, ['seat', 'task']);
  assert.deepEqual(pi.tools.get('fablepowers_dispatch').parameters.properties.seat.enum, ['implementer', 'strict_implementer', 'reviewer']);
  assert.equal(pi.tools.get('fablepowers_ask_approval').executionMode, undefined);
  assert.deepEqual([...pi.commands.keys()].sort(), ['fablepowers:approve', 'fablepowers:withdraw']);
  assert.deepEqual(pi.flagDefs.get('fablepowers-child').type, 'boolean');
  for (const ev of ['session_start', 'session_shutdown', 'before_agent_start', 'tool_call', 'tool_result']) {
    assert.equal(pi.handlers[ev]?.length, 1, ev);
  }
});

test('guard: a second factory run before session_shutdown registers nothing; after it, registers again', async () => {
  const pi1 = load();
  const pi2 = fakePi();
  createExtension({ root: ROOT, env: envWith(), piInvocation: invocation })(pi2);
  assert.equal(pi2.tools.size, 0);
  assert.equal(pi2.commands.size, 0);
  assert.equal(Object.keys(pi2.handlers).length, 0);
  // a copy at another path (the case Pi otherwise fails on with "Tool ... conflicts")
  const pi3 = fakePi();
  createExtension({ root: tmpdir('other-copy'), env: envWith() })(pi3);
  assert.equal(pi3.tools.size, 0);
  await pi1.emit('session_shutdown', { type: 'session_shutdown', reason: 'new' }, fakeCtx({ cwd: TMP }));
  const pi4 = fakePi();
  createExtension({ root: ROOT, env: envWith(), piInvocation: invocation })(pi4);
  assert.equal(pi4.tools.size, 2);
  assert.equal(pi4.commands.size, 2);
  // the old generation's shutdown cannot clear the new generation's guard
  await pi1.emit('session_shutdown', { type: 'session_shutdown', reason: 'quit' }, fakeCtx({ cwd: TMP }));
  const pi5 = fakePi();
  createExtension({ root: ROOT, env: envWith() })(pi5);
  assert.equal(pi5.tools.size, 0);
  delete globalThis[GUARD];
});

// --- bootstrap ---------------------------------------------------------------------------

const bootEvent = () => ({ type: 'before_agent_start', messageType: 'user', prompt: 'hi', systemPrompt: 'base', systemPromptOptions: { cwd: TMP, sections: {} } });

test('bootstrap: root session gets the fablepowers_workflow section from session-start --pi', { skip }, async () => {
  const pi = load({ env: envWith({}, PINNED) });
  const ctx = fakeCtx({ cwd: newRepo() });
  await pi.emit('session_start', { type: 'session_start', reason: 'startup' }, ctx);
  const ev = bootEvent();
  await pi.emit('before_agent_start', ev, ctx);
  const text = ev.systemPromptOptions.sections[SECTION];
  assert.match(text, /^You have fablepowers on Pi\./);
  assert.match(text, /Skill names: a skill written `fablepowers:<x>` is the Pi skill `fablepowers-<x>`/);
  assert.match(text, /implementer.*openrouter\/qwen\/qwen3\.6-flash/);
  assert.match(text, /# Workflow Map/);
  assert.ok(text.length <= 8000, `bootstrap ${text.length} chars`);
  // a missing sections object is created
  const ev2 = bootEvent(); delete ev2.systemPromptOptions.sections;
  await pi.emit('before_agent_start', ev2, ctx);
  assert.equal(ev2.systemPromptOptions.sections[SECTION], text);
});

test('bootstrap: none in a child (env AND flag); env without the flag is a root session with a note', async () => {
  const env = envWith({ FABLEPOWERS_PARENT_SESSION: 'p1', FABLEPOWERS_SEAT: 'implementer' });
  const child = load({ env, flags: { 'fablepowers-child': true }, getPpid: () => 4242 });
  const ctx = fakeCtx({ cwd: newRepo() });
  await child.emit('session_start', { type: 'session_start', reason: 'startup' }, ctx);
  const ev = bootEvent();
  await child.emit('before_agent_start', ev, ctx);
  assert.equal(ev.systemPromptOptions.sections[SECTION], undefined);
  await child.emit('session_shutdown', { type: 'session_shutdown', reason: 'quit' }, ctx);

  const half = load({ env });
  await half.emit('session_start', { type: 'session_start', reason: 'startup' }, ctx);
  const ev2 = bootEvent();
  await half.emit('before_agent_start', ev2, ctx);
  assert.match(ev2.systemPromptOptions.sections[SECTION], /FABLEPOWERS_PARENT_SESSION is set but this Pi was not started with --fablepowers-child/);
});

test('bootstrap: no python -> the gate-off note; session-start failure -> note and the plain workflow map', async () => {
  const fakeBash = path.join(tmpdir('bash'), 'bash');
  fs.writeFileSync(fakeBash, '#!/bin/sh\necho not-json\n', { mode: 0o755 });
  const pi = load({ env: envWith({ FABLEPOWERS_PYTHON: '/nonexistent/python3', FABLEPOWERS_BASH: fakeBash }) });
  const ctx = fakeCtx({ cwd: newRepo() });
  const ev = bootEvent();
  await pi.emit('before_agent_start', ev, ctx);
  const text = ev.systemPromptOptions.sections[SECTION];
  assert.match(text, /^fablepowers approval gate disabled: python3 not found/);
  assert.match(text, /hooks\/session-start failed \(its output was not the expected JSON\)/);
  assert.match(text, /# Workflow Map/);
  assert.doesNotMatch(text, /^---/m);
});

test('bootstrap: the JS-appended notes fit the 8,000-char cap (N6)', { skip }, async () => {
  // (a) session-start answered: its context (Task 2 worst case 7322 chars) plus the
  // notes that can join it (no python, env without the flag); Task 4 may add <= 120.
  const pi = load({ env: envWith({ FABLEPOWERS_PYTHON: '/nonexistent/python3', FABLEPOWERS_PARENT_SESSION: 'x' }) });
  const ev = bootEvent();
  await pi.emit('before_agent_start', ev, fakeCtx({ cwd: newRepo() }));
  const text = ev.systemPromptOptions.sections[SECTION];
  assert.match(text, /^fablepowers approval gate disabled[\s\S]*FABLEPOWERS_PARENT_SESSION is set[\s\S]*You have fablepowers on Pi/);
  const notes = text.slice(0, text.indexOf('You have fablepowers on Pi'));
  assert.ok(notes.length + 7322 + 120 <= 8000, `notes ${notes.length} chars`);
  // (b) session-start failed: every note plus the plain workflow map, with room for a
  // plugin root 200 chars longer than this checkout's and Task 4's 120.
  const fakeBash = path.join(tmpdir('bash'), 'bash');
  fs.writeFileSync(fakeBash, '#!/bin/sh\necho not-json\n', { mode: 0o755 });
  const pi2 = load({ env: envWith({ FABLEPOWERS_PYTHON: '/nonexistent/python3', FABLEPOWERS_BASH: fakeBash, FABLEPOWERS_PARENT_SESSION: 'x' }) });
  const ev2 = bootEvent();
  await pi2.emit('before_agent_start', ev2, fakeCtx({ cwd: newRepo() }));
  const text2 = ev2.systemPromptOptions.sections[SECTION];
  assert.match(text2, /^fablepowers approval gate disabled[\s\S]*hooks\/session-start failed[\s\S]*FABLEPOWERS_PARENT_SESSION is set[\s\S]*# Workflow Map/);
  assert.ok(text2.length + 200 + 120 <= 8000, `fallback bootstrap ${text2.length} chars`);
});

test('session_start is idempotent: one child log line and one watchdog across repeated events', async () => {
  const repo = newRepo();
  const env = envWith({ FABLEPOWERS_PARENT_SESSION: 'p1', FABLEPOWERS_SEAT: 'reviewer', FABLEPOWERS_PARENT_PID: '4242' });
  let ppid = 4242;
  let exits = 0;
  const pi = load({ env, flags: { 'fablepowers-child': true }, getPpid: () => ppid, watchdogMs: 20, exitGraceMs: 10, exit: () => { exits++; } });
  const ctx = fakeCtx({ cwd: repo, mode: 'json' });
  await pi.emit('session_start', { type: 'session_start', reason: 'startup' }, ctx);
  await pi.emit('session_start', { type: 'session_start', reason: 'startup' }, ctx);
  assert.equal(gateLog(repo).match(/loaded in child seat=reviewer parent=p1; gate (on|off)/g)?.length, 1);
  await sleep(80);
  assert.equal(ctx.aborts, 0, 'parent alive: no abort');
  ppid = 1;
  await sleep(120);
  assert.equal(ctx.aborts, 1, 'one watchdog fired once');
  assert.equal(ctx.shutdowns, 1);
  assert.equal(exits, 1);
  assert.match(gateLog(repo), /child watchdog: the parent process is gone/);
  await pi.emit('session_shutdown', { type: 'session_shutdown', reason: 'quit' }, ctx);
});

test('watchdog: not started in a root session; stopped by session_shutdown in a child', async () => {
  let calls = 0;
  const root = load({ getPpid: () => { calls++; return 7; }, watchdogMs: 10 });
  await root.emit('session_start', { type: 'session_start', reason: 'startup' }, fakeCtx({ cwd: newRepo() }));
  await sleep(50);
  assert.equal(calls, 0);
  await root.emit('session_shutdown', { type: 'session_shutdown', reason: 'quit' }, fakeCtx({ cwd: TMP }));

  let ppid = 50;
  const env = envWith({ FABLEPOWERS_PARENT_SESSION: 'p1' });
  const child = load({ env, flags: { 'fablepowers-child': true }, getPpid: () => ppid, watchdogMs: 20, exit: () => {} });
  const ctx = fakeCtx({ cwd: newRepo(), mode: 'json' });
  await child.emit('session_start', { type: 'session_start', reason: 'startup' }, ctx);
  await child.emit('session_shutdown', { type: 'session_shutdown', reason: 'quit' }, ctx);
  ppid = 1;
  await sleep(80);
  assert.equal(ctx.aborts, 0);
});

// --- paths (Q-G1, SF5: the resolver lives here) -------------------------------------------

test('resolveToCwd copies Pi: @ prefix, ~, file://, unicode spaces, relative and absolute', () => {
  const cwd = '/work/repo';
  const h = '/home/u';
  assert.equal(resolveToCwd('@docs/plans/a.md', cwd, h), '/work/repo/docs/plans/a.md');
  assert.equal(resolveToCwd('~/x.md', cwd, h), '/home/u/x.md');
  assert.equal(resolveToCwd('~', cwd, h), '/home/u');
  assert.equal(resolveToCwd('@~/x.md', cwd, h), '/home/u/x.md');
  assert.equal(resolveToCwd('file:///work/repo/src/a.py', cwd, h), '/work/repo/src/a.py');
  assert.equal(resolveToCwd('docs/specs/a b.md', cwd, h), '/work/repo/docs/specs/a b.md');
  assert.equal(resolveToCwd('docs/specs/../../src/x.py', cwd, h), '/work/repo/src/x.py');
  assert.equal(resolveToCwd('/abs//p/../q', cwd, h), '/abs/q');
  assert.equal(resolveToCwd('@@x', cwd, h), '/work/repo/@x');
  assert.equal(resolveToCwd('a~/b', cwd, h), '/work/repo/a~/b');
  assert.equal(resolveToCwd('x', '~/repo', h), '/home/u/repo/x');
});

test('tool_call rewrites write/edit input.path to the absolute path it gated; reads are untouched', { skip }, async () => {
  const repo = newRepo();
  const h = home();
  const pi = load({ home: h });
  const ctx = fakeCtx({ cwd: repo });
  for (const [raw, want] of [
    ['@docs/plans/a.md', path.join(repo, 'docs/plans/a.md')],
    ['~/notes.md', path.join(h, 'notes.md')],
    [pathToFileURL(path.join(repo, 'src', 'b.py')).href, path.join(repo, 'src', 'b.py')],
    ['src/sub/../c d.py', path.join(repo, 'src', 'c d.py')],
  ]) {
    const { event } = await write(pi, ctx, raw);
    assert.equal(event.input.path, want, raw);
    const { event: e2 } = await write(pi, ctx, raw, 'edit');
    assert.equal(e2.input.path, want, `edit ${raw}`);
  }
  const read = { type: 'tool_call', toolName: 'read', toolCallId: 'r1', input: { path: '@src/app.py' } };
  assert.equal(await pi.emit('tool_call', read, ctx), undefined);
  assert.equal(read.input.path, '@src/app.py');
});

// --- the gate contract rows, through the real gate ----------------------------------------

test('tool_result: a created docs/specs/*.md goes pending and the notice is appended to the result', { skip }, async () => {
  const repo = newRepo();
  const pi = load();
  const ctx = fakeCtx({ cwd: repo, mode: 'tui' });
  const r = await createSpec(pi, ctx, repo, 'docs/specs/feat.md');
  assert.ok(r && Array.isArray(r.content));
  assert.equal(r.content[0].text, 'Successfully wrote to docs/specs/feat.md');
  assert.match(r.content[1].text, /design `docs\/specs\/feat\.md` \(key `feat`\) is now pending/);
  assert.deepEqual(readJson(pendingMarker(repo, 'feat')).spec, 'docs/specs/feat.md');
});

test('tool_result: an overwrite, an error result, an edit and a child write do not go pending', { skip }, async () => {
  const repo = newRepo();
  const pi = load();
  const ctx = fakeCtx({ cwd: repo });
  fs.writeFileSync(path.join(repo, 'docs/specs/old.md'), '# old\n');
  const { event } = await write(pi, ctx, 'docs/specs/old.md');
  assert.equal(await pi.emit('tool_result', { type: 'tool_result', toolName: 'write', toolCallId: event.toolCallId, input: event.input, content: [], isError: false }, ctx), undefined);
  assert.ok(!fs.existsSync(pendingMarker(repo, 'old')));
  const { event: e2 } = await write(pi, ctx, 'docs/specs/err.md');
  fs.writeFileSync(e2.input.path, '# x\n');
  assert.equal(await pi.emit('tool_result', { type: 'tool_result', toolName: 'write', toolCallId: e2.toolCallId, input: e2.input, content: [], isError: true }, ctx), undefined);
  assert.ok(!fs.existsSync(pendingMarker(repo, 'err')));
  const { event: e3 } = await write(pi, ctx, 'docs/specs/ed.md', 'edit');
  fs.writeFileSync(e3.input.path, '# x\n');
  assert.equal(await pi.emit('tool_result', { type: 'tool_result', toolName: 'edit', toolCallId: e3.toolCallId, input: e3.input, content: [], isError: false }, ctx), undefined);
  assert.ok(!fs.existsSync(pendingMarker(repo, 'ed')));

  const child = load({ env: envWith({ FABLEPOWERS_PARENT_SESSION: 'p' }), flags: { 'fablepowers-child': true }, getPpid: () => 99 });
  const cctx = fakeCtx({ cwd: repo, mode: 'json' });
  await child.emit('session_start', { type: 'session_start', reason: 'startup' }, cctx);
  await createSpec(child, cctx, repo, 'docs/specs/kid.md');
  assert.ok(!fs.existsSync(pendingMarker(repo, 'kid')));
  await child.emit('session_shutdown', { type: 'session_shutdown', reason: 'quit' }, cctx);
});

test('SF4: a write tool_result with no existed record is counted as a create, and logged', { skip }, async () => {
  const repo = newRepo();
  const pi = load();
  const ctx = fakeCtx({ cwd: repo });
  const p = path.join(repo, 'docs/specs/norec.md');
  fs.writeFileSync(p, '# x\n');
  const r = await pi.emit('tool_result', { type: 'tool_result', toolName: 'write', toolCallId: 'never-seen', input: { path: p }, content: [], isError: false }, ctx);
  assert.match(r.content[0].text, /now pending/);
  assert.match(gateLog(repo), /without an existed record; counted as a create/);
});

test('tool_call while pending: write/edit outside the allowlist blocked, allowlist and reads pass, markers always blocked', { skip }, async () => {
  const repo = newRepo();
  const pi = load();
  const ctx = fakeCtx({ cwd: repo });
  assert.equal((await write(pi, ctx, 'src/app.py')).block, undefined, 'nothing pending: src write allowed');
  const m = await write(pi, ctx, '.fablepowers/x/approved');
  assert.equal(m.block.block, true, 'marker write blocked with nothing pending');
  assert.match(m.block.reason, /Approval markers/);
  await createSpec(pi, ctx, repo, 'docs/specs/feat.md');
  for (const tool of ['write', 'edit']) {
    const r = await write(pi, ctx, '@src/app.py', tool);
    assert.equal(r.block.block, true, tool);
    assert.match(r.block.reason, /docs\/specs\/feat\.md.*awaits the user's approval/);
    assert.match(r.block.reason, /\/fablepowers:approve feat/);
  }
  assert.equal((await write(pi, ctx, 'docs/plans/p.md')).block, undefined);
  assert.equal((await write(pi, ctx, '@docs/specs/feat.md', 'edit')).block, undefined);
  assert.equal((await write(pi, ctx, '.fablepowers/feat/progress.md')).block, undefined);
  assert.equal((await write(pi, ctx, path.join(tmpdir('elsewhere'), 'x.py'))).block, undefined);
  assert.equal((await write(pi, ctx, '~/.pi/agent/settings.json')).block.block, true, 'Pi config blocked');
  assert.equal(await pi.emit('tool_call', { type: 'tool_call', toolName: 'read', toolCallId: 'r', input: { path: 'src/app.py' } }, ctx), undefined, 'SF2 read');
  // SF4: a write/edit with no path: denied while pending (and allowed when nothing is)
  const nopath = await pi.emit('tool_call', { type: 'tool_call', toolName: 'write', toolCallId: 'np', input: { content: 'x' } }, ctx);
  assert.equal(nopath.block, true);
  assert.match(gateLog(repo), /without an absolute path/);
  const repo2 = newRepo();
  assert.equal(await pi.emit('tool_call', { type: 'tool_call', toolName: 'edit', toolCallId: 'np2', input: {} }, fakeCtx({ cwd: repo2 })), undefined);
});

test('$PI_CODING_AGENT_DIR reaches the gate: writes under it blocked while pending (Q-K1, N8)', { skip }, async () => {
  const repo = newRepo();
  const agentDir = tmpdir('agentdir');
  const pi = load({ env: envWith({ PI_CODING_AGENT_DIR: agentDir }) });
  const ctx = fakeCtx({ cwd: repo });
  assert.equal((await write(pi, ctx, path.join(agentDir, 'settings.json'))).block, undefined, 'nothing pending');
  await createSpec(pi, ctx, repo, 'docs/specs/feat.md');
  const r = await write(pi, ctx, path.join(agentDir, 'settings.json'));
  assert.equal(r.block?.block, true);
  assert.match(r.block.reason, /Pi config/);
  const plain = load();
  assert.equal((await write(plain, ctx, path.join(agentDir, 'settings.json'))).block, undefined, 'without the variable it is just outside the repo');
});

test('dispatch row: implementer blocked, reviewer allowed, the subagent tool blocked in every form while pending', { skip }, async () => {
  const repo = newRepo();
  const pi = load();
  const ctx = fakeCtx({ cwd: repo });
  const call = (toolName, input) => pi.emit('tool_call', { type: 'tool_call', toolName, toolCallId: `d${++callN}`, input }, ctx);
  assert.equal(await call('fablepowers_dispatch', { seat: 'implementer', task: 't' }), undefined, 'nothing pending');
  await createSpec(pi, ctx, repo, 'docs/specs/feat.md');
  for (const seat of ['implementer', 'strict_implementer', 'Reviewer', undefined]) {
    const r = await call('fablepowers_dispatch', { seat, task: 't' });
    assert.equal(r?.block, true, String(seat));
  }
  assert.equal(await call('fablepowers_dispatch', { seat: 'reviewer', task: 't' }), undefined);
  for (const name of ['tool_call-subagent-single', 'tool_call-subagent-parallel', 'tool_call-subagent-chain']) {
    const r = await call('subagent', fixture(name).event.input);
    assert.equal(r?.block, true, name);
  }
});

test('command row: approve records via command, withdraw clears pending; result to the model and the user, never stdout', { skip }, async () => {
  const repo = newRepo();
  const pi = load();
  const tui = fakeCtx({ cwd: repo, mode: 'tui' });
  await createSpec(pi, tui, repo, 'docs/specs/feat.md');
  const realWrite = process.stdout.write;
  let stdoutWrites = 0;
  process.stdout.write = (...a) => { stdoutWrites++; return realWrite.apply(process.stdout, a); };
  try {
    await pi.commands.get('fablepowers:approve').handler('  feat  ', tui);
  } finally { process.stdout.write = realWrite; }
  assert.equal(stdoutWrites, 0);
  assert.equal(readJson(approvedMarker(repo, 'feat')).via, 'command');
  const last = pi.sent.at(-1);
  assert.equal(last.m.customType, RESULT_TYPE);
  assert.equal(last.m.display, true);
  assert.deepEqual(last.o, { triggerTurn: false });
  assert.match(last.m.content, /the user approved design `docs\/specs\/feat\.md`/);
  assert.match(last.m.content, /fablepowers-implementation-plan/);
  assert.equal(tui.notes.length, 1);
  assert.equal(tui.notes[0].k, 'info');
  assert.equal(pi.stderr.lines.length, 0);

  await createSpec(pi, tui, repo, 'docs/specs/other.md');
  const print = fakeCtx({ cwd: repo, mode: 'print' });
  await pi.commands.get('fablepowers:withdraw').handler('other', print);
  assert.ok(!fs.existsSync(pendingMarker(repo, 'other')));
  assert.match(pi.stderr.lines.at(-1), /the user withdrew design `docs\/specs\/other\.md`/);
  assert.equal(print.notes.length, 0);
});

test('refusal rule: PI_SESSION_ID in any mode (the TUI included), an unknown mode, and a child session cannot approve', { skip }, async () => {
  const repo = newRepo();
  const base = load();
  await createSpec(base, fakeCtx({ cwd: repo }), repo, 'docs/specs/feat.md');
  const forged = load({ env: envWith({ PI_SESSION_ID: 'abc' }) });
  // S1: a model can give a shell-started pi a pty (`script -qec ...`), so the TUI is not exempt
  for (const mode of ['tui', 'print', 'json', 'rpc', undefined]) {
    const ctx = fakeCtx({ cwd: repo, mode: 'print' });
    ctx.mode = mode; // undefined: a ctx without a mode (SF4: fails closed)
    await forged.commands.get('fablepowers:approve').handler('', ctx);
    assert.ok(!fs.existsSync(approvedMarker(repo, 'feat')), String(mode));
    assert.match(forged.sent.at(-1).m.content, /inside another Pi's shell/);
    // SF-1: speaks to the user's action, never to "you", and does not name the variable
    assert.match(forged.sent.at(-1).m.content, /The user must type `\/fablepowers:approve` in a Pi they started in their own terminal/);
    assert.doesNotMatch(forged.sent.at(-1).m.content, /PI_SESSION_ID|yourself|you started/);
    assert.doesNotMatch(forged.sent.at(-1).m.content, /interactive/);
  }
  await forged.commands.get('fablepowers:withdraw').handler('', fakeCtx({ cwd: repo, mode: 'tui' }));
  assert.ok(fs.existsSync(pendingMarker(repo, 'feat')));
  const child = load({ env: envWith({ FABLEPOWERS_PARENT_SESSION: 'p' }), flags: { 'fablepowers-child': true }, getPpid: () => 9 });
  await child.commands.get('fablepowers:approve').handler('', fakeCtx({ cwd: repo, mode: 'json' }));
  assert.ok(!fs.existsSync(approvedMarker(repo, 'feat')));
  assert.match(child.sent.at(-1).m.content, /dispatched child session/);
  // a Pi the user started (no PI_SESSION_ID) may approve
  await base.commands.get('fablepowers:approve').handler('', fakeCtx({ cwd: repo, mode: 'tui' }));
  assert.equal(readJson(approvedMarker(repo, 'feat')).via, 'command');
});

test('approval tool: one pending -> Approve/Changes needed dialog naming the gate\'s design; the model\'s spec is ignored', { skip }, async () => {
  const repo = newRepo();
  const pi = load();
  const ctx = fakeCtx({ cwd: repo, mode: 'tui', select: () => 'Approve' });
  await createSpec(pi, ctx, repo, 'docs/specs/feat.md');
  const tool = pi.tools.get('fablepowers_ask_approval');
  const r = await tool.execute('t1', { spec: 'docs/specs/somethingelse.md' }, undefined, undefined, ctx);
  assert.equal(ctx.selects.length, 1);
  assert.deepEqual(ctx.selects[0].options, ['Approve', 'Changes needed']);
  assert.match(ctx.selects[0].title, /docs\/specs\/feat\.md/);
  assert.doesNotMatch(ctx.selects[0].title, /somethingelse/);
  assert.equal(readJson(approvedMarker(repo, 'feat')).via, 'question');
  assert.match(r.content[0].text, /the user approved design `docs\/specs\/feat\.md`/);
});

test('approval tool: Changes needed and a dismissed dialog record nothing', { skip }, async () => {
  const repo = newRepo();
  const pi = load();
  for (const [answer, re] of [['Changes needed', /chose Changes needed/], [undefined, /got no answer/]]) {
    const ctx = fakeCtx({ cwd: repo, mode: 'rpc', select: () => answer });
    await createSpec(pi, ctx, repo, 'docs/specs/feat.md');
    const r = await pi.tools.get('fablepowers_ask_approval').execute('t', {}, undefined, undefined, ctx);
    assert.match(r.content[0].text, re);
    assert.ok(!fs.existsSync(approvedMarker(repo, 'feat')));
  }
});

test('approval tool: several pending -> one entry per design plus Changes needed; only the chosen key is approved', { skip }, async () => {
  const repo = newRepo();
  const pi = load();
  const ctx = fakeCtx({ cwd: repo, mode: 'tui', select: (_t, opts) => opts[1] });
  await createSpec(pi, ctx, repo, 'docs/specs/a.md');
  await createSpec(pi, ctx, repo, 'docs/specs/b.md');
  await pi.tools.get('fablepowers_ask_approval').execute('t', { spec: 'docs/specs/a.md' }, undefined, undefined, ctx);
  assert.deepEqual(ctx.selects[0].options, ['Approve docs/specs/a.md', 'Approve docs/specs/b.md', 'Changes needed']);
  assert.ok(!fs.existsSync(approvedMarker(repo, 'a')));
  assert.equal(readJson(approvedMarker(repo, 'b')).via, 'question');
});

test('approval tool: a key withdrawn while the dialog was open records nothing', { skip }, async () => {
  const repo = newRepo();
  const pi = load();
  const ctx = fakeCtx({ cwd: repo, mode: 'tui', select: () => { fs.rmSync(pendingMarker(repo, 'feat')); return 'Approve'; } });
  await createSpec(pi, ctx, repo, 'docs/specs/feat.md');
  const r = await pi.tools.get('fablepowers_ask_approval').execute('t', {}, undefined, undefined, ctx);
  assert.ok(!fs.existsSync(approvedMarker(repo, 'feat')));
  assert.match(r.content[0].text, /not recorded because no design is pending/);
});

test('approval tool: refused sessions and print mode get no dialog', { skip }, async () => {
  const repo = newRepo();
  await createSpec(load(), fakeCtx({ cwd: repo }), repo, 'docs/specs/feat.md');
  const cases = [
    ['PI_SESSION_ID + rpc', load({ env: envWith({ PI_SESSION_ID: 'x' }) }), 'rpc', /approvals are refused in this session/],
    ['PI_SESSION_ID + tui (S1)', load({ env: envWith({ PI_SESSION_ID: 'x' }) }), 'tui', /approvals are refused in this session.*inside another Pi's shell/],
    ['child', load({ env: envWith({ FABLEPOWERS_PARENT_SESSION: 'p' }), flags: { 'fablepowers-child': true }, getPpid: () => 3 }), 'rpc', /dispatched child session/],
    ['print (no UI)', load(), 'print', /no UI in this mode.*\/fablepowers:approve feat/],
  ];
  for (const [label, pi, mode, re] of cases) {
    const ctx = fakeCtx({ cwd: repo, mode, select: () => 'Approve' });
    const r = await pi.tools.get('fablepowers_ask_approval').execute('t', {}, undefined, undefined, ctx);
    assert.equal(ctx.selects.length, 0, label);
    assert.match(r.content[0].text, re, label);
    assert.ok(!fs.existsSync(approvedMarker(repo, 'feat')), label);
  }
  const none = newRepo();
  const ctx = fakeCtx({ cwd: none, mode: 'tui', select: () => 'Approve' });
  const r = await load().tools.get('fablepowers_ask_approval').execute('t', {}, undefined, undefined, ctx);
  assert.equal(ctx.selects.length, 0);
  assert.match(r.content[0].text, /no design is pending/);
});

// --- fail-open (SF4) ----------------------------------------------------------------------

function fakePython(body) {
  const d = tmpdir('py');
  const p = path.join(d, 'python3');
  // answers the launcher's version probe (-I -c ...), then runs `body` as the gate
  fs.writeFileSync(p, `#!/bin/sh\nif [ "$2" = "-c" ]; then exit 0; fi\ncat >/dev/null\n${body}\n`, { mode: 0o755 });
  return p;
}

test('fail open: gate timeout, non-JSON gate output and missing python never block; each is logged', async () => {
  for (const [label, py, re] of [
    ['timeout', fakePython('sleep 5'), /gate call \(tool_call\) timed out after 150 ms; allowed/],
    ['garbage', fakePython('echo "{not json"'), /gate call \(tool_call\) returned no JSON object; allowed/],
    ['deny-shaped garbage', fakePython('echo \'{"decision":"deny"}\''), null],
  ]) {
    const repo = newRepo();
    const pi = load({ env: envWith({ FABLEPOWERS_PYTHON: py }), gateTimeoutMs: 150 });
    const ctx = fakeCtx({ cwd: repo });
    assert.equal((await write(pi, ctx, 'src/app.py')).block, undefined, label);
    assert.equal(await pi.emit('tool_call', { type: 'tool_call', toolName: 'fablepowers_dispatch', toolCallId: 'x', input: { seat: 'implementer', task: 't' } }, ctx), undefined, label);
    if (re) assert.match(gateLog(repo), re, label);
  }
  const repo = newRepo();
  const pi = load({ env: envWith({ FABLEPOWERS_PYTHON: '/nonexistent/python3' }) });
  const ctx = fakeCtx({ cwd: repo, mode: 'tui', select: () => 'Approve' });
  assert.equal((await write(pi, ctx, 'src/app.py')).block, undefined);
  const r = await pi.tools.get('fablepowers_ask_approval').execute('t', {}, undefined, undefined, ctx);
  assert.equal(ctx.selects.length, 0);
  assert.match(r.content[0].text, /python3 not found/);
  await pi.commands.get('fablepowers:approve').handler('', ctx);
  assert.match(pi.sent.at(-1).m.content, /python3 not found, so `\/fablepowers:approve` recorded nothing/);
  assert.equal(ctx.notes.at(-1).k, 'error');
});

test('fail open: a handler that throws returns nothing and logs', async () => {
  const repo = newRepo();
  const pi = load();
  const ctx = fakeCtx({ cwd: repo });
  const boom = (type) => ({ type, get toolName() { throw new Error('boom-' + type); } });
  assert.equal(await pi.emit('tool_call', boom('tool_call'), ctx), undefined);
  assert.equal(await pi.emit('tool_result', { type: 'tool_result', toolCallId: 'x', get toolName() { throw new Error('boom-tr'); } }, ctx), undefined);
  assert.equal(await pi.emit('before_agent_start', { type: 'before_agent_start', get systemPromptOptions() { throw new Error('boom-bas'); } }, ctx), undefined);
  const log = gateLog(repo);
  assert.match(log, /tool_call failed, allowed: Error: boom-tool_call/);
  assert.match(log, /tool_result failed, allowed: Error: boom-tr/);
  assert.match(log, /before_agent_start failed, allowed: Error: boom-bas/);
  // a command whose gate gives no answer says so, visibly
  const pi2 = load({ env: envWith({ FABLEPOWERS_PYTHON: fakePython('echo nope') }) });
  await pi2.commands.get('fablepowers:approve').handler('', fakeCtx({ cwd: repo, mode: 'print' }));
  assert.match(pi2.stderr.lines.at(-1), /may not have been recorded: the gate call returned no JSON object/);
  // the approval tool with an ill-shaped pending answer shows no dialog
  const pi3 = load({ env: envWith({ FABLEPOWERS_PYTHON: fakePython('echo "{}"') }) });
  const c3 = fakeCtx({ cwd: repo, mode: 'tui', select: () => 'Approve' });
  const r = await pi3.tools.get('fablepowers_ask_approval').execute('t', {}, undefined, undefined, c3);
  assert.equal(c3.selects.length, 0);
  assert.match(r.content[0].text, /could not list the pending designs/);
});

// --- dispatch (fake pi) ----------------------------------------------------------------------

async function dispatch(pi, ctx, params, signal) {
  return pi.tools.get('fablepowers_dispatch').execute(`disp-${++callN}`, params, signal, undefined, ctx);
}
const echoOf = (r) => JSON.parse(r.content[0].text.split('\n\n').find((s) => s.startsWith('{"argv"')));

test('dispatch: a pinned seat runs the child with its model, thinking, flag, env and a frontmatter-free role prompt', { skip }, async () => {
  const repo = newRepo();
  const sdir = tmpdir('sessions');
  const pi = load({ env: envWith({ FAKE_PI_MODE: 'echo', FAKE_PI_MODEL: 'openrouter/qwen/qwen3.6-flash', FAKE_PI_THINKING: 'low' }, PINNED) });
  const ctx = fakeCtx({ cwd: repo, sessionFile: path.join(sdir, 'parent.jsonl'), sessionDir: sdir, sessionId: 'sess-P' });
  await pi.emit('session_start', { type: 'session_start', reason: 'startup' }, ctx);
  const r = await dispatch(pi, ctx, { seat: 'implementer', task: 'Do the thing' });
  assert.equal(r.isError, undefined, r.content[0].text);
  const e = echoOf(r);
  const a = e.argv;
  assert.deepEqual(a.slice(0, 2), ['--mode', 'json']);
  assert.ok(a.includes('-p'));
  const childDir = path.join(sdir, 'fablepowers-children', 'sess-P');
  assert.equal(a[a.indexOf('--session-dir') + 1], childDir);
  assert.equal(a[a.indexOf('-e') + 1], ROOT);
  assert.ok(a.includes('--fablepowers-child=1'));
  assert.ok(!a.includes('--fablepowers-child'), 'never the bare flag (it swallows the next argument)');
  assert.equal(a[a.indexOf('--model') + 1], 'openrouter/qwen/qwen3.6-flash');
  assert.equal(a[a.indexOf('--thinking') + 1], 'low');
  assert.equal(a.at(-1), 'Task: Do the thing');
  assert.equal(e.env.FABLEPOWERS_PARENT_SESSION, 'sess-P');
  assert.equal(e.env.FABLEPOWERS_SEAT, 'implementer');
  assert.equal(e.env.FABLEPOWERS_PARENT_PID, String(process.pid));
  assert.equal(e.cwd, repo);
  // role prompt: agents/implementer.md body, frontmatter stripped
  assert.doesNotMatch(e.prompt, /^---$/m);
  assert.doesNotMatch(e.prompt, /^name: implementer$/m);
  assert.match(e.prompt, /You implement exactly one task from an approved implementation plan/);
  assert.match(e.prompt, /^You are the fablepowers implementer seat/);
  assert.ok(!fs.existsSync(a[a.indexOf('--append-system-prompt') + 1]), 'temp role prompt removed afterwards');
  // result details (Q-D8) and the child transcript link
  assert.deepEqual(Object.keys(r.details).sort(), ['childSessionFile', 'exitCode', 'model', 'seat', 'usage']);
  assert.equal(r.details.seat, 'implementer');
  assert.equal(r.details.model, 'openrouter/qwen/qwen3.6-flash');
  assert.equal(r.details.exitCode, 0);
  assert.equal(r.details.usage.turns, 1);
  assert.equal(path.dirname(r.details.childSessionFile), childDir);
  assert.ok(fs.existsSync(r.details.childSessionFile));
  assert.equal(pi.entries.at(-1).type, 'fablepowers-child');
  assert.equal(pi.entries.at(-1).data.childSessionFile, r.details.childSessionFile);
  assert.doesNotMatch(r.content[0].text, /Warning/);
});

test('dispatch: an unpinned seat inherits the session model and thinking; a --no-session parent uses the temp dir', { skip }, async () => {
  const repo = newRepo();
  const t = tmpdir('tmproot');
  const pi = load({ env: envWith({ FAKE_PI_MODE: 'echo' }), tmpdir: t });
  const ctx = fakeCtx({ cwd: repo, sessionFile: undefined, sessionDir: '/nonexistent/default', sessionId: 'sess-N', model: { provider: 'prov', id: 'm/x' }, thinkingLevel: 'minimal' });
  const r = await dispatch(pi, ctx, { seat: 'strict_implementer', task: 'T' });
  const a = echoOf(r).argv;
  assert.equal(a[a.indexOf('--model') + 1], 'prov/m/x');
  assert.equal(a[a.indexOf('--thinking') + 1], 'minimal');
  assert.equal(a[a.indexOf('--session-dir') + 1], path.join(t, 'fablepowers-children', 'sess-N'));
  assert.match(echoOf(r).prompt, /fablepowers strict-implementer seat/);
  assert.match(r.content[0].text, /unpinned: session model/);
});

test('dispatch: a task over 64 KiB goes through a temp file referenced as "Task: read <file>"', { skip }, async () => {
  const repo = newRepo();
  const pi = load({ env: envWith({ FAKE_PI_MODE: 'echo' }) });
  const big = `BEGIN${'y'.repeat(70 * 1024)}END`;
  const r = await dispatch(pi, fakeCtx({ cwd: repo }), { seat: 'reviewer', task: big });
  const e = echoOf(r);
  assert.match(e.argv.at(-1), /^Task: read \S+task\.md and do the task it describes\.$/);
  assert.deepEqual(e.taskFile, { length: big.length, head: big.slice(0, 40), tail: big.slice(-40) });
  assert.ok(!fs.existsSync(/^Task: read (\S+) /.exec(e.argv.at(-1))[1]), 'temp task file removed afterwards');
  const atLimit = `Q${'z'.repeat(64 * 1024 - 1)}`;
  const small = echoOf(await dispatch(pi, fakeCtx({ cwd: repo }), { seat: 'reviewer', task: atLimit }));
  assert.deepEqual(small.argv.at(-1), { length: atLimit.length + 6, head: `Task: ${atLimit.slice(0, 34)}`, tail: atLimit.slice(-40) });
  assert.equal(small.taskFile, null);
});

test('dispatch: output capped at 50 KB with a note; model mismatch warns; failure is an error with stderr', { skip }, async () => {
  const repo = newRepo();
  const big = await dispatch(load({ env: envWith({ FAKE_PI_MODE: 'big' }) }), fakeCtx({ cwd: repo }), { seat: 'reviewer', task: 't' });
  const text = big.content[0].text;
  assert.match(text, /BIG-START/);
  assert.doesNotMatch(text, /BIG-END/);
  assert.match(text, /\[Output truncated: \d+ bytes omitted\. The child's full transcript: /);
  assert.ok(Buffer.byteLength(text) < OUTPUT_CAP + 1024);

  const mm = await dispatch(load({ env: envWith({ FAKE_PI_MODE: 'normal', FAKE_PI_MODEL: 'openrouter/other/model' }, PINNED) }), fakeCtx({ cwd: repo }), { seat: 'implementer', task: 't' });
  assert.match(mm.content[0].text, /^Warning: the child reported model openrouter\/other\/model, not the seat's openrouter\/qwen\/qwen3\.6-flash/);
  assert.equal(mm.isError, undefined, 'a mismatch warns, it does not fail');
  const mt = await dispatch(load({ env: envWith({ FAKE_PI_MODE: 'normal', FAKE_PI_THINKING: 'high' }, PINNED) }), fakeCtx({ cwd: repo }), { seat: 'implementer', task: 't' });
  assert.match(mt.content[0].text, /^Warning: the child reported thinking high, not the seat's low/);

  const f = await dispatch(load({ env: envWith({ FAKE_PI_MODE: 'fail' }) }), fakeCtx({ cwd: repo }), { seat: 'reviewer', task: 't' });
  assert.equal(f.isError, true);
  assert.match(f.content[0].text, /the child exited with code 3/);
  assert.match(f.content[0].text, /stopped with error: provider exploded/);
  assert.match(f.content[0].text, /child stderr \(tail\): fake child: provider exploded/);
  assert.equal(f.details.exitCode, 3);
});

test('dispatch: a child that cannot be started is an error result, not a hang', { skip, timeout: 20000 }, async () => {
  const pi = load({ piInvocation: (args) => ({ command: path.join(TMP, 'no-such-pi'), args }) });
  const r = await dispatch(pi, fakeCtx({ cwd: newRepo() }), { seat: 'reviewer', task: 't' });
  assert.equal(r.isError, true);
  assert.match(r.content[0].text, /the child could not be run: spawn \S+no-such-pi ENOENT/);
  assert.equal(r.details.exitCode, 1);
});

async function waitFor(fn, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const v = fn(); if (v) return v; await sleep(20); }
  throw new Error('timed out waiting');
}
const isAlive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

test('kill on exit: session_shutdown SIGTERMs a live child (SF1)', { skip, timeout: 20000 }, async () => {
  const repo = newRepo();
  const pidfile = path.join(tmpdir('pid'), 'pid');
  const pi = load({ env: envWith({ FAKE_PI_MODE: 'hang', FAKE_PI_PIDFILE: pidfile }) });
  const ctx = fakeCtx({ cwd: repo });
  const run = dispatch(pi, ctx, { seat: 'reviewer', task: 't' });
  const pid = Number(await waitFor(() => fs.existsSync(pidfile) && fs.readFileSync(pidfile, 'utf8')));
  assert.ok(isAlive(pid));
  await pi.emit('session_shutdown', { type: 'session_shutdown', reason: 'quit' }, ctx);
  const r = await run;
  assert.ok(!isAlive(pid));
  assert.equal(r.isError, true);
  assert.match(r.content[0].text, /SIGTERM/);
});

test('kill on exit: a child that ignores SIGTERM gets SIGKILL after the grace period', { skip, timeout: 20000 }, async () => {
  const repo = newRepo();
  const pidfile = path.join(tmpdir('pid'), 'pid');
  const pi = load({ env: envWith({ FAKE_PI_MODE: 'ignore-term', FAKE_PI_PIDFILE: pidfile }), killGraceMs: 400 });
  const ctx = fakeCtx({ cwd: repo });
  const run = dispatch(pi, ctx, { seat: 'reviewer', task: 't' });
  const pid = Number(await waitFor(() => fs.existsSync(pidfile) && fs.readFileSync(pidfile, 'utf8')));
  await sleep(100); // let it install its SIGTERM handler
  await pi.emit('session_shutdown', { type: 'session_shutdown', reason: 'quit' }, ctx);
  await sleep(150);
  assert.ok(isAlive(pid), 'still alive inside the grace period');
  const r = await run;
  assert.ok(!isAlive(pid));
  assert.match(r.content[0].text, /SIGKILL/);
});

test('abort: the tool signal stops the child and the call rejects', { skip, timeout: 20000 }, async () => {
  const repo = newRepo();
  const pidfile = path.join(tmpdir('pid'), 'pid');
  const pi = load({ env: envWith({ FAKE_PI_MODE: 'hang', FAKE_PI_PIDFILE: pidfile }) });
  const ac = new AbortController();
  const run = dispatch(pi, fakeCtx({ cwd: repo }), { seat: 'reviewer', task: 't' }, ac.signal);
  const pid = Number(await waitFor(() => fs.existsSync(pidfile) && fs.readFileSync(pidfile, 'utf8')));
  ac.abort();
  await assert.rejects(run, /was aborted/);
  assert.ok(!isAlive(pid));
  assert.equal(pi.entries.at(-1).type, 'fablepowers-child');
});

test('dispatch is refused in a child (no sub-dispatch), for an unknown seat and an empty task; nothing spawns', async () => {
  const repo = newRepo();
  let spawns = 0;
  const spy = (...a) => { spawns++; return spawn(...a); };
  const child = load({ env: envWith({ FABLEPOWERS_PARENT_SESSION: 'p' }), flags: { 'fablepowers-child': true }, spawn: spy, getPpid: () => 5 });
  const r = await dispatch(child, fakeCtx({ cwd: repo, mode: 'json' }), { seat: 'reviewer', task: 't' });
  assert.equal(r.isError, true);
  assert.match(r.content[0].text, /not available in a dispatched child session/);
  const half = load({ env: envWith({ FABLEPOWERS_PARENT_SESSION: 'p' }), spawn: spy });
  assert.match((await dispatch(half, fakeCtx({ cwd: repo }), { seat: 'reviewer', task: 't' })).content[0].text, /not available in a dispatched child/);
  const pi = load({ spawn: spy });
  assert.match((await dispatch(pi, fakeCtx({ cwd: repo }), { seat: 'boss', task: 't' })).content[0].text, /unknown seat "boss"/);
  assert.match((await dispatch(pi, fakeCtx({ cwd: repo }), { seat: 'reviewer', task: '  ' })).content[0].text, /the task is empty/);
  assert.equal(spawns, 0);
});

test('dispatch cwd (SF11): inside the repo or a linked worktree accepted; outside or a symlink escape rejected', { skip }, async () => {
  const repo = newRepo();
  spawnSync('git', ['-C', repo, 'commit', '-q', '--allow-empty', '-m', 'init'], { env: { ...BASE_ENV, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@e', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@e' } });
  const wt = path.join(tmpdir('wtparent'), 'wt');
  assert.equal(spawnSync('git', ['-C', repo, 'worktree', 'add', '-q', wt, '-b', 'wt'], { env: BASE_ENV }).status, 0);
  const outside = tmpdir('outside');
  fs.symlinkSync(outside, path.join(repo, 'src', 'escape'));
  let spawns = 0;
  const spy = (...a) => { spawns++; return spawn(...a); };
  const pi = load({ env: envWith({ FAKE_PI_MODE: 'echo' }), spawn: spy });
  const ctx = fakeCtx({ cwd: repo });
  assert.equal(echoOf(await dispatch(pi, ctx, { seat: 'reviewer', task: 't', cwd: 'src' })).cwd, path.join(repo, 'src'));
  assert.equal(echoOf(await dispatch(pi, ctx, { seat: 'reviewer', task: 't', cwd: wt })).cwd, fs.realpathSync(wt));
  assert.equal(spawns, 2);
  for (const bad of [outside, 'src/escape', '/', '../', 'nope/missing']) {
    const r = await dispatch(pi, ctx, { seat: 'reviewer', task: 't', cwd: bad });
    assert.equal(r.isError, true, bad);
    assert.match(r.content[0].text, /^dispatch rejected: /, bad);
  }
  assert.equal(spawns, 2);
});

test('piInvocationFor: argv[1] realpath\'d (symlinked launcher), compiled binary, pi on PATH', () => {
  const d = tmpdir('inv');
  const real = path.join(d, 'cli.js');
  fs.writeFileSync(real, '');
  const link = path.join(d, 'pi');
  fs.symlinkSync(real, link);
  assert.deepEqual(piInvocationFor(['-p'], { argv1: link, execPath: '/usr/bin/node' }), { command: '/usr/bin/node', args: [real, '-p'] });
  assert.deepEqual(piInvocationFor(['-p'], { argv1: '', execPath: '/opt/pi/pi-bin' }), { command: '/opt/pi/pi-bin', args: ['-p'] });
  assert.deepEqual(piInvocationFor(['-p'], { argv1: path.join(d, 'missing'), execPath: '/usr/bin/node' }), { command: 'pi', args: ['-p'] });
});

// --- wrappers, manifest, NOTICE -------------------------------------------------------------

function tree(dir) {
  const out = {};
  for (const ent of fs.readdirSync(dir, { withFileTypes: true, recursive: true })) {
    if (!ent.isFile()) continue;
    const p = path.join(ent.parentPath ?? ent.path, ent.name);
    out[path.relative(dir, p)] = fs.readFileSync(p, 'utf8');
  }
  return out;
}

test('wrapper drift: scripts/gen-pi-skills.sh output equals the committed pi/skills', () => {
  const out = tmpdir('gen');
  const r = spawnSync('bash', [path.join(ROOT, 'scripts', 'gen-pi-skills.sh'), out], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(tree(out), tree(path.join(ROOT, 'pi', 'skills')));
});

test('wrappers: one per model-invocable skill (user-only ones excluded by rule), pointing at an existing SKILL.md', () => {
  const skillsDir = path.join(ROOT, 'skills');
  const want = fs.readdirSync(skillsDir).filter((s) => {
    const p = path.join(skillsDir, s, 'SKILL.md');
    return fs.existsSync(p) && createExtension.internals.stripFrontmatter(fs.readFileSync(p, 'utf8')).meta['disable-model-invocation'] !== 'true';
  }).map((s) => `fablepowers-${s}`).sort();
  const have = fs.readdirSync(path.join(ROOT, 'pi', 'skills')).sort();
  assert.deepEqual(have, want);
  assert.ok(!have.includes('fablepowers-approve') && !have.includes('fablepowers-withdraw'));
  assert.ok(have.includes('fablepowers-workflow'));
  for (const w of have) {
    const file = path.join(ROOT, 'pi', 'skills', w, 'SKILL.md');
    const { meta, body } = createExtension.internals.stripFrontmatter(fs.readFileSync(file, 'utf8'));
    const x = w.slice('fablepowers-'.length);
    assert.equal(meta.name, w);
    assert.match(meta.name, /^[a-z0-9-]{1,64}$/);
    const orig = createExtension.internals.stripFrontmatter(fs.readFileSync(path.join(skillsDir, x, 'SKILL.md'), 'utf8')).meta;
    assert.equal(meta.description, orig.description);
    const rel = `../../../skills/${x}/SKILL.md`;
    assert.ok(body.includes(rel), w);
    assert.ok(fs.existsSync(path.resolve(path.dirname(file), rel)), `${w} -> ${rel}`);
  }
});

test('package.json pi field and NOTICE credit', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
  assert.deepEqual(pkg.pi, { extensions: ['./pi/fablepowers.ts'], skills: ['./pi/skills'] });
  assert.equal(pkg.main, 'opencode/index.js');
  for (const p of pkg.pi.extensions.concat(pkg.pi.skills)) assert.ok(fs.existsSync(path.join(ROOT, p)), p);
  const notice = fs.readFileSync(path.join(ROOT, 'NOTICE'), 'utf8');
  assert.match(notice, /pi\/fablepowers\.ts/);
  assert.match(notice, /examples\/extensions\/subagent/);
  assert.match(notice, /earendil-works/);
  assert.match(notice, /Mario Zechner/);
});

test('capOutput: linear on 200k CJK/emoji characters, never splits a character, exact byte budget', () => {
  const lone = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;
  const cases = [
    ['CJK', '\u4e2d'.repeat(200000)],
    ['emoji', '\u{1F600}'.repeat(200000)],
    ['mixed', 'a\u00e9\u4e2d\u{1F600}'.repeat(50000)],
  ];
  for (const [label, text] of cases) {
    for (const cap of [OUTPUT_CAP, 1001, 1002, 1003, 1, 0]) {
      const t0 = performance.now();
      const out = capOutput(text, cap, '/x/s.jsonl');
      const ms = performance.now() - t0;
      assert.ok(ms < 100, `${label} cap ${cap}: ${ms.toFixed(1)} ms`);
      const cut = out.slice(0, out.indexOf('\n\n[Output truncated: '));
      assert.ok(text.startsWith(cut), `${label} cap ${cap}: a prefix`);
      assert.doesNotMatch(cut, lone, `${label} cap ${cap}: no lone surrogate`);
      assert.ok(!cut.includes('\uFFFD'), `${label} cap ${cap}: no replacement char`);
      const bytes = Buffer.byteLength(cut, 'utf8');
      assert.ok(bytes <= cap, `${label} cap ${cap}: ${bytes} <= cap`);
      // the longest whole-character prefix: one more character would exceed the cap
      const next = String.fromCodePoint(text.codePointAt(cut.length));
      assert.ok(bytes + Buffer.byteLength(next, 'utf8') > cap, `${label} cap ${cap}: maximal prefix`);
      const dropped = Buffer.byteLength(text, 'utf8') - bytes;
      assert.match(out, new RegExp(`\\[Output truncated: ${dropped} bytes omitted\\. The child's full transcript: /x/s\\.jsonl\\]$`));
    }
  }
  assert.equal(capOutput('\u4e2d\u{1F600}', 7, ''), '\u4e2d\u{1F600}');
});
