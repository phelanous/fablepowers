// Tests for the OpenCode plugin adapter (opencode/index.js), run with `node --test`
// (tests/opencode/run.sh). A fake `ctx` models OpenCode 2.0.29's plugin surface
// (skill/agent/command transforms, session/tool/permission hooks, session.get,
// session.synthetic); hook events come from the real payloads committed under
// tests/opencode/fixtures/. Integration tests run the REAL hooks/approval_gate.py
// and hooks/session-start against temp git repos (one per gate contract row).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const FIX = path.join(HERE, 'fixtures');
const { createPlugin } = await import(path.join(ROOT, 'opencode', 'index.js'));
const { BOOTSTRAP_TAG, stripWrappingQuotes, findPython } = createPlugin.internals;

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'fp-oc-test-'));
process.on('exit', () => fs.rmSync(TMP, { recursive: true, force: true }));
let n = 0;
const tmpdir = (name) => { const d = path.join(TMP, `${name}-${++n}`); fs.mkdirSync(d, { recursive: true }); return fs.realpathSync(d); };

const BASE_ENV = { ...process.env };
for (const k of ['FABLEPOWERS_GATE', 'FABLEPOWERS_PYTHON', 'FABLEPOWERS_BASH', 'XDG_CONFIG_HOME']) delete BASE_ENV[k];
const REAL_PYTHON = findPython(BASE_ENV);
const ROOT_SID = 'ses_ebd5a99f3ffeF5vPi54JXAWmlv';
const CHILD_SID = 'ses_ebd5a5d19ffeeuCWPM7BMia7Gz';
const SERVE_SID = 'ses_ebd57ee19ffedY6kFQQpZ9Vhxd';

function home(models) {
  const h = tmpdir('home');
  if (models !== undefined) {
    fs.mkdirSync(path.join(h, '.config', 'fablepowers'), { recursive: true });
    fs.writeFileSync(path.join(h, '.config', 'fablepowers', 'models.toml'), models);
  }
  return h;
}
const envWith = (extra = {}) => ({ ...BASE_ENV, HOME: home(), ...extra });

function newRepo() {
  const r = tmpdir('repo');
  spawnSync('git', ['init', '-q', r]);
  for (const d of ['docs/specs', 'docs/plans', 'src', 'sub']) fs.mkdirSync(path.join(r, d), { recursive: true });
  return r;
}

// fixture(name, repo): the recorded hook object (payload.ev, or payload.input for
// commands) with __ROOT__ -> repo and __PLUGIN__ -> the plugin root.
function fixture(name, repo) {
  const raw = fs.readFileSync(path.join(FIX, `${name}.json`), 'utf8')
    .replaceAll('__ROOT__', repo).replaceAll('__PLUGIN__', ROOT);
  const p = JSON.parse(raw).payload;
  return p.ev ?? p.input ?? p.record ?? p;
}

// A fake OpenCode ctx. sessions: {sid: record}; unknown sids get a root record
// whose location is `repo`. getFails: session.get rejects. ctx.location is a
// directory that is NOT the session directory (MF2).
function fakeCtx({ repo, sessions = {}, getFails = false, locationDir } = {}) {
  const hooks = {};
  const skills = new Map();
  const builtins = ['build', 'plan', 'general', 'explore'].map((id) => fixture(`agent-transform-builtin-${id}`, repo || '/x')).map((p) => p.a);
  const agents = new Map(builtins.map((a) => [a.id, structuredClone(a)]));
  const commands = new Map();
  const synthetic = [];
  const calls = { skill: 0, agent: 0, command: 0, get: 0 };
  const newAgent = (id) => ({
    id, name: id, request: { settings: {}, headers: {}, body: {} }, mode: 'primary', hidden: false,
    permissions: [{ action: '*', resource: '*', effect: 'allow' }, { action: 'read', resource: '*.env', effect: 'ask' }],
  });
  const reg = (kind) => async (name, fn) => { (hooks[`${kind}.${name}`] ||= []).push(fn); };
  return {
    hooks, skills, agents, commands, synthetic, calls, builtinsBefore: structuredClone(builtins),
    location: { directory: locationDir ?? tmpdir('elsewhere') },
    skill: { transform: async (f) => { calls.skill++; f({ add: (s) => { if (skills.has(s.id)) throw new Error('dup skill'); skills.set(s.id, s); }, get: (id) => skills.get(id), list: () => [...skills.values()] }); } },
    agent: {
      transform: async (f) => {
        calls.agent++;
        f({
          list: () => [...agents.values()], get: (id) => agents.get(id), default: () => 'build', remove: (id) => agents.delete(id),
          update: (id, fn) => { if (!agents.has(id)) agents.set(id, newAgent(id)); fn(agents.get(id)); },
        });
      },
    },
    command: { transform: async (f) => { calls.command++; f({ add: (c) => { if (commands.has(c.name)) throw new Error('dup cmd'); commands.set(c.name, c); }, get: (n) => commands.get(n) }); } },
    session: {
      hook: reg('session'),
      get: async ({ sessionID }) => {
        calls.get++;
        if (getFails) throw new Error('lookup failed');
        if (sessions[sessionID]) return structuredClone(sessions[sessionID]);
        return { id: sessionID, location: { directory: repo } };
      },
      synthetic: async (x) => { synthetic.push(x); return { id: 'msg_x', type: 'synthetic', payload: { text: x.text } }; },
    },
    tool: { hook: reg('tool') },
    permission: { hook: reg('permission') },
  };
}
const childSessions = (repo, dir = repo) => ({
  [CHILD_SID]: { id: CHILD_SID, parentID: ROOT_SID, agent: 'general', location: { directory: dir } },
});

async function boot(opts = {}, ctxOpts = {}) {
  const repo = ctxOpts.repo ?? newRepo();
  const ctx = fakeCtx({ repo, sessions: childSessions(repo), ...ctxOpts });
  const plugin = createPlugin({ env: envWith(), ...opts });
  await plugin.setup(ctx);
  const hook = (name) => {
    const fns = ctx.hooks[name] || [];
    assert.equal(fns.length, 1, `exactly one ${name} hook`);
    return fns[0];
  };
  return { repo, ctx, plugin, hook };
}

const fp = (repo, ...p) => path.join(repo, '.fablepowers', ...p);
const exists = (p) => fs.existsSync(p);
const readLog = (repo) => { try { return fs.readFileSync(fp(repo, 'gate.log'), 'utf8'); } catch { return ''; } };

// A fake python that passes the version check, records each payload, prints `out`.
function fakePython({ out = '{}', sleep = 0, exit = 0 } = {}) {
  const d = tmpdir('fakepy');
  const rec = path.join(d, 'payloads.jsonl');
  const p = path.join(d, 'python3');
  fs.writeFileSync(p, `#!/bin/sh
if [ "$2" = "-c" ]; then exit 0; fi
cat >> "${rec}"; echo >> "${rec}"
${sleep ? `sleep ${sleep}` : ''}
printf '%s\\n' '${out}'
exit ${exit}
`);
  fs.chmodSync(p, 0o755);
  return { python: p, payloads: () => (exists(rec) ? fs.readFileSync(rec, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []) };
}

// spec create via the after hook (the file is written first, as the tool did).
async function createSpec(hook, repo, rel = 'docs/specs/a.md', { sid = ROOT_SID, dir = repo } = {}) {
  fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
  fs.writeFileSync(path.join(dir, rel), '# spec\n');
  const ev = fixture('after-write-root-created', repo);
  ev.sessionID = sid;
  ev.input.path = rel;
  ev.result.output.resource = rel;
  ev.result.output.target = path.join(dir, rel);
  await hook('tool.execute.after')(ev);
  return ev;
}
const permEdit = (repo, resource, sid = ROOT_SID) => {
  const ev = fixture('permission-edit-root-modified', repo);
  ev.sessionID = sid; ev.resources = [resource]; ev.metadata.files = [{ file: resource, status: 'modified' }]; ev.effect = 'ask';
  return ev;
};
const permSub = (repo, agent, name = 'permission-subagent-root') => {
  const ev = fixture(name, repo); ev.resources = [agent]; ev.effect = 'ask'; return ev;
};

// --- registration ---------------------------------------------------------------------------

test('skills: every skills/*/SKILL.md except approve/withdraw, as fablepowers:<name>', async () => {
  const { ctx } = await boot();
  const want = fs.readdirSync(path.join(ROOT, 'skills')).filter((d) => exists(path.join(ROOT, 'skills', d, 'SKILL.md')) && !['approve', 'withdraw'].includes(d)).sort();
  assert.deepEqual([...ctx.skills.keys()].sort(), want.map((d) => `fablepowers:${d}`));
  const s = ctx.skills.get('fablepowers:design-spec');
  assert.equal(s.name, 'fablepowers:design-spec');
  assert.equal(s.path, path.join(ROOT, 'skills', 'design-spec', 'SKILL.md'));
  assert.match(s.description, /^Use before implementing/);
  assert.ok(!s.content.startsWith('---'), 'frontmatter stripped');
  assert.ok(!ctx.skills.has('fablepowers:approve') && !ctx.skills.has('fablepowers:withdraw'));
});

const SEAT_FILES = [['fablepowers-implementer', 'implementer.md'], ['fablepowers-strict-implementer', 'strict-implementer.md'], ['fablepowers-reviewer', 'reviewer.md']];
const roleBody = (file) => fs.readFileSync(path.join(ROOT, 'agents', file), 'utf8').replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, '').trim();

test('agents: three subagent seats, role prompt inlined, no sub-spawn, no external_directory grant; built-ins untouched', async () => {
  const { ctx } = await boot();
  for (const [id, file] of SEAT_FILES) {
    const a = ctx.agents.get(id);
    assert.ok(a, id);
    assert.equal(a.mode, 'subagent');
    assert.ok(a.system.includes(path.join(ROOT, 'agents', file)), `${id} system names its role file`);
    const body = roleBody(file);
    assert.ok(body.length > 200, `${id} role body is substantial`);
    assert.ok(a.system.includes(body), `${id} system carries the role prompt body`);
    assert.ok(!/^---$/m.test(a.system) && !/^(model|disallowedTools):/m.test(a.system), `${id} frontmatter stripped`);
    assert.ok(!/read that file first/.test(a.system), `${id} no read-the-file instruction when inlined`);
    assert.ok(a.description && a.description.length > 20);
    assert.ok(a.permissions.some((p) => p.action === 'subagent' && p.resource === '*' && p.effect === 'deny'));
    assert.ok(!a.permissions.some((p) => p.action === 'external_directory' && p.effect === 'allow'), `${id} has no external_directory allow`);
    assert.ok(!a.permissions.some((p) => typeof p.resource === 'string' && p.resource.startsWith(ROOT)), `${id} has no plugin-root rule`);
    // the deny comes after the default `* allow` (last match wins)
    const iAllow = a.permissions.findIndex((p) => p.action === '*' && p.effect === 'allow');
    const iDeny = a.permissions.findIndex((p) => p.action === 'subagent' && p.effect === 'deny');
    assert.ok(iDeny > iAllow);
    assert.equal(a.model, undefined, 'unpinned: session model');
  }
  // Task 0: built-in agents already allow external access; C9 changes nothing there.
  for (const b of ctx.builtinsBefore) assert.deepEqual(ctx.agents.get(b.id), b);
});

test('agents: a missing or unreadable role file falls back to the pointer text, logged; others still inlined (fail open)', async () => {
  const root = tmpdir('plugin-root');
  for (const d of ['skills', 'hooks']) fs.symlinkSync(path.join(ROOT, d), path.join(root, d));
  fs.mkdirSync(path.join(root, 'agents'));
  fs.copyFileSync(path.join(ROOT, 'agents', 'reviewer.md'), path.join(root, 'agents', 'reviewer.md'));
  fs.mkdirSync(path.join(root, 'agents', 'strict-implementer.md')); // unreadable as a file (EISDIR)
  // implementer.md missing (ENOENT)
  const repo = newRepo();
  const { ctx } = await boot({ root }, { repo, locationDir: repo });
  for (const [id, file] of [['fablepowers-implementer', 'implementer.md'], ['fablepowers-strict-implementer', 'strict-implementer.md']]) {
    const a = ctx.agents.get(id);
    assert.ok(a, `${id} still registered`);
    assert.equal(a.mode, 'subagent');
    assert.ok(a.system.includes(`Your role instructions are in \`${path.join(root, 'agents', file)}\`: read that file first`), `${id} pointer fallback`);
    assert.ok(!a.permissions.some((p) => p.action === 'external_directory'), `${id} fallback adds no grant`);
    assert.ok(a.permissions.some((p) => p.action === 'subagent' && p.effect === 'deny'));
  }
  const rev = ctx.agents.get('fablepowers-reviewer');
  assert.ok(rev.system.includes(roleBody('reviewer.md')), 'reviewer still inlined');
  const log = fs.readFileSync(path.join(repo, '.fablepowers', 'gate.log'), 'utf8');
  assert.match(log, /seat fablepowers-implementer: could not read role file .*implementer\.md \(ENOENT\)/);
  assert.match(log, /seat fablepowers-strict-implementer: could not read role file .*strict-implementer\.md \(EISDIR\)/);
  assert.ok(!/seat fablepowers-reviewer/.test(log), 'no warning for a readable role file');
  // A role file with frontmatter but an empty body: pointer fallback too, logged.
  fs.writeFileSync(path.join(root, 'agents', 'implementer.md'), '---\nname: implementer\ndescription: Empty-body implementer role file for the test.\n---\n\n');
  const repo2 = newRepo();
  const { ctx: ctx2 } = await boot({ root }, { repo: repo2, locationDir: repo2 });
  assert.match(ctx2.agents.get('fablepowers-implementer').system, /: read that file first and follow it\.$/);
  assert.match(fs.readFileSync(path.join(repo2, '.fablepowers', 'gate.log'), 'utf8'), /seat fablepowers-implementer: role file .*implementer\.md has an empty body/);
});

test('agents: pinned seats get model {providerID, id, variant} from models.toml [opencode] (C1)', async () => {
  const h = home('[codex]\nimplementer = "gpt-5"\n[opencode]\nimplementer = "opencode/big-pickle#high"\nreviewer = "openrouter/anthropic/claude-x.1"\n');
  const { ctx } = await boot({ env: { ...BASE_ENV, HOME: h } });
  assert.deepEqual(ctx.agents.get('fablepowers-implementer').model, { providerID: 'opencode', id: 'big-pickle', variant: 'high' });
  assert.deepEqual(ctx.agents.get('fablepowers-reviewer').model, { providerID: 'openrouter', id: 'anthropic/claude-x.1' });
  assert.equal(ctx.agents.get('fablepowers-strict-implementer').model, undefined);
});

test('commands: fablepowers:approve and fablepowers:withdraw, one closure each', async () => {
  const { ctx } = await boot();
  assert.deepEqual([...ctx.commands.keys()].sort(), ['fablepowers:approve', 'fablepowers:withdraw']);
  for (const c of ctx.commands.values()) assert.equal(typeof c.execute, 'function');
});

test('registration is idempotent per instance; each instance (location) registers once', async () => {
  const repo = newRepo();
  const plugin = createPlugin({ env: envWith() });
  const ctx = fakeCtx({ repo });
  await plugin.setup(ctx);
  await plugin.setup(ctx);
  assert.deepEqual(ctx.calls, { skill: 1, agent: 1, command: 1, get: 0 });
  for (const k of ['permission.evaluate', 'tool.execute.before', 'tool.execute.after', 'session.prompt', 'session.context']) {
    assert.equal(ctx.hooks[k].length, 1, k);
  }
  // A second location (another ctx) on the same plugin instance registers too (no process-global flag).
  const ctx3 = fakeCtx({ repo });
  await plugin.setup(ctx3);
  assert.equal(ctx3.calls.skill, 1);
  assert.ok(ctx3.agents.has('fablepowers-reviewer'));
});

// --- model pin ---------------------------------------------------------------------------------

test('execute.before strips a per-dispatch model only for pinned fablepowers seats', async () => {
  const h = home('[opencode]\nimplementer = "opencode/big-pickle"\n');
  const { hook, repo } = await boot({ env: { ...BASE_ENV, HOME: h } });
  const before = hook('tool.execute.before');
  const ev = (agent) => { const e = fixture('before-subagent-seat', repo); e.input.agent = agent; e.input.model = 'opencode/other'; return e; };
  const pinned = ev('fablepowers-implementer');
  await before(pinned);
  assert.ok(!('model' in pinned.input), 'pinned seat: model stripped');
  const unpinned = ev('fablepowers-reviewer');
  await before(unpinned);
  assert.equal(unpinned.input.model, 'opencode/other', 'unpinned seat keeps the model');
  const other = ev('general');
  await before(other);
  assert.equal(other.input.model, 'opencode/other', 'non-seat keeps the model');
});

// --- bootstrap --------------------------------------------------------------------------------

function ctxEvent(repo, sid, messages) {
  const e = fixture('context-root-trimmed', repo);
  return { sessionID: sid, agent: e.agent, model: e.model, system: [], options: {}, tools: {}, messages };
}
const userMsg = (text) => ({ role: 'user', content: [{ type: 'text', text }] });

test('context: bootstrap (preamble, seat table, workflow map) prepended to the first user message of root sessions only', async () => {
  const { hook, repo } = await boot();
  const ev = ctxEvent(repo, ROOT_SID, [userMsg('hi'), { role: 'assistant', content: [{ type: 'text', text: 'ok' }] }, userMsg('more')]);
  await hook('session.context')(ev);
  const first = ev.messages[0].content[0].text;
  assert.ok(first.startsWith(`<${BOOTSTRAP_TAG}>`));
  assert.ok(first.includes('You have fablepowers on OpenCode'));
  assert.ok(first.includes('Seat table'));
  assert.ok(first.includes('# Workflow Map'));
  assert.ok(first.includes('unpinned seats run on the session model'));
  assert.ok(first.includes('on OpenCode `fablepowers-<agent>`'), 'N1: the map names the OpenCode seat ids');
  assert.equal(ev.messages[0].content[1].text, 'hi');
  assert.equal(ev.messages[2].content.length, 1, 'only the first user message');
  await hook('session.context')(ev);
  assert.equal(ev.messages[0].content.filter((p) => p.text.includes(BOOTSTRAP_TAG)).length, 1, 'not doubled');
  const child = ctxEvent(repo, CHILD_SID, [userMsg('task')]);
  await hook('session.context')(child);
  assert.equal(child.messages[0].content.length, 1, 'child sessions get no bootstrap');
});

test('context (SF-A): a tag mention in reasoning, assistant text or a later user message does not suppress the bootstrap; never doubled', async () => {
  const { hook, repo } = await boot();
  const tag = `<${BOOTSTRAP_TAG}>`;
  const ev = ctxEvent(repo, ROOT_SID, [
    userMsg('design a feature'),
    { role: 'assistant', content: [{ type: 'reasoning', text: `The ${tag} block says to read opencode.md first.` }] },
    { role: 'assistant', content: [{ type: 'text', text: `Per the ${tag} block, I start with design-spec.` }] },
    userMsg(`${tag} quoted by the user`),
  ]);
  await hook('session.context')(ev);
  const first = ev.messages[0].content;
  assert.ok(first[0].text.startsWith(tag) && first[0].text.includes('Seat table'), 'bootstrap injected');
  assert.equal(first[1].text, 'design a feature');
  assert.equal(ev.messages[3].content.length, 1, 'the later user message is untouched');
  await hook('session.context')(ev);
  await hook('session.context')(ev);
  const count = ev.messages.flatMap((m) => m.content).filter((p) => p.text.startsWith(tag) && p.text.includes('Seat table')).length;
  assert.equal(count, 1, 'not doubled across steps');
  // A user message that starts with the tag but is not the plugin's part does not count as applied.
  const fake = ctxEvent(repo, ROOT_SID, [userMsg(`${tag}\nnot the real bootstrap\n</${BOOTSTRAP_TAG}>`)]);
  await hook('session.context')(fake);
  assert.equal(fake.messages[0].content.length, 2);
  assert.ok(fake.messages[0].content[0].text.includes('Seat table'));
});

test('context: re-applied after compaction (no user message left: appended)', async () => {
  const { hook, repo } = await boot();
  const ev = ctxEvent(repo, ROOT_SID, [{ role: 'assistant', content: [{ type: 'text', text: 'summary checkpoint' }] }]);
  await hook('session.context')(ev);
  assert.equal(ev.messages.length, 2);
  assert.equal(ev.messages[1].role, 'user');
  assert.ok(ev.messages[1].content[0].text.includes('You have fablepowers on OpenCode'));
  await hook('session.context')(ev);
  assert.equal(ev.messages.length, 2, 'appended once, not again on the same step view');
  assert.equal(ev.messages[1].content.length, 1);
  // A fresh message array of the next step (OpenCode reloads from the DB): applied again.
  const next = ctxEvent(repo, ROOT_SID, [userMsg('after compaction')]);
  await hook('session.context')(next);
  assert.ok(next.messages[0].content[0].text.includes(BOOTSTRAP_TAG));
});

test('context: a failed session lookup still injects (fail open)', async () => {
  const { hook, repo } = await boot({}, { getFails: true });
  const ev = ctxEvent(repo, ROOT_SID, [userMsg('hi')]);
  await hook('session.context')(ev);
  assert.ok(ev.messages[0].content[0].text.includes(BOOTSTRAP_TAG));
});

test('models.toml with [codex] and [opencode]: no cross-warnings in the OpenCode bootstrap', async () => {
  const h = home('[codex]\nimplementer = "gpt-5.5"\nimplementer_effort = "high"\n[opencode]\nimplementer = "opencode/a"\nstrict_implementer = "opencode/b"\nreviewer = "opencode/c#max"\n');
  const { hook, repo } = await boot({ env: { ...BASE_ENV, HOME: h } });
  const ev = ctxEvent(repo, ROOT_SID, [userMsg('hi')]);
  await hook('session.context')(ev);
  const t = ev.messages[0].content[0].text;
  assert.ok(!t.includes('warnings'), t.slice(0, 1500));
  assert.ok(t.includes('model opencode/c, variant max'));
});

// --- payload shape (fake python records what it receives) ---------------------------------------

test('payload shape per contract row; cwd = session.get().location.directory, not ctx.location or process.cwd()', async () => {
  const fake = fakePython();
  const { hook, ctx, repo } = await boot({ env: envWith({ FABLEPOWERS_PYTHON: fake.python }) });
  assert.notEqual(ctx.location.directory, repo);
  const sub = path.join(repo, 'sub');
  const pe = fixture('permission-write-root-added', repo);
  await hook('permission.evaluate')(pe);
  const ch = fixture('permission-write-child-added', repo);
  ch.sessionID = CHILD_SID;
  await hook('permission.evaluate')(ch);
  await hook('permission.evaluate')(fixture('permission-read-root', repo)); // not edit/subagent: no call
  const bs = fixture('before-subagent-seat', repo);
  await hook('tool.execute.before')(bs);
  await hook('tool.execute.before')(fixture('before-read-root', repo)); // no call
  const af = fixture('after-write-root-created', repo);
  await hook('tool.execute.after')(af);
  await hook('tool.execute.after')(fixture('after-read-root', repo)); // no call
  const pr = { sessionID: ROOT_SID, prompt: { text: '"/fablepowers:approve key1"' } };
  await hook('session.prompt')(pr);
  await hook('session.prompt')({ sessionID: ROOT_SID, prompt: { text: 'just chatting' } }); // no call
  await ctx.commands.get('fablepowers:withdraw').execute(fixture('command-approve', repo));
  const P = fake.payloads();
  assert.equal(P.length, 6);
  for (const p of P) {
    assert.equal(p.harness, 'opencode');
    assert.equal(p.cwd, repo);
    assert.equal(p.plugin_root, ROOT);
    assert.ok(!('parent_unknown' in p));
  }
  assert.deepEqual(P[0], { harness: 'opencode', hook: 'permission', cwd: repo, session_id: ROOT_SID, parent_id: null, plugin_root: ROOT,
    action: 'edit', resources: ['docs/specs/a.md'], files: pe.metadata.files });
  assert.equal(P[1].parent_id, ROOT_SID);
  assert.equal(P[1].session_id, CHILD_SID);
  assert.deepEqual([P[2].hook, P[2].tool, P[2].input.agent], ['before', 'subagent', 'fp-seat-varmodel']);
  assert.deepEqual({ hook: P[3].hook, tool: P[3].tool, status: P[3].status, output: P[3].output, existed: P[3].existed, input: P[3].input },
    { hook: 'after', tool: 'write', status: 'completed', output: af.result.output, existed: {}, input: af.input });
  assert.deepEqual([P[4].hook, P[4].text], ['prompt', '/fablepowers:approve key1']);
  assert.deepEqual([P[5].hook, P[5].verb, P[5].args, P[5].session_id], ['command', 'withdraw', 'foo bar', SERVE_SID]);
  assert.ok(sub);
});

test('payload: a failed parent lookup sends parent_id null + parent_unknown, cwd falls back to ctx.location', async () => {
  const fake = fakePython();
  const repo = newRepo();
  const { hook } = await boot({ env: envWith({ FABLEPOWERS_PYTHON: fake.python }) }, { repo, getFails: true, locationDir: repo });
  await hook('permission.evaluate')(fixture('permission-write-root-added', repo));
  const [p] = fake.payloads();
  assert.equal(p.parent_id, null);
  assert.equal(p.parent_unknown, true);
  assert.equal(p.cwd, repo);
});

test('payload: a session record with the wrong id or a malformed parentID counts as a failed lookup', async () => {
  for (const rec of [{ id: 'ses_other' }, { id: ROOT_SID, parentID: '' }, { id: ROOT_SID, parentID: 7 }]) {
    const fake = fakePython();
    const repo = newRepo();
    const { hook } = await boot({ env: envWith({ FABLEPOWERS_PYTHON: fake.python }) },
      { repo, locationDir: repo, sessions: { [ROOT_SID]: { ...rec, location: { directory: repo } } } });
    await hook('permission.evaluate')(fixture('permission-write-root-added', repo));
    const [p] = fake.payloads();
    assert.equal(p.parent_unknown, true, JSON.stringify(rec));
    assert.equal(p.parent_id, null);
  }
});

test('SF4: one wrapping quote pair stripped, no more', () => {
  assert.equal(stripWrappingQuotes('"/fablepowers:approve a"'), '/fablepowers:approve a');
  assert.equal(stripWrappingQuotes("'/fablepowers:approve'"), '/fablepowers:approve');
  assert.equal(stripWrappingQuotes('""/fablepowers:approve""'), '"/fablepowers:approve"');
  assert.equal(stripWrappingQuotes('"/fablepowers:approve'), '"/fablepowers:approve');
  assert.equal(stripWrappingQuotes('"/fablepowers:approve\''), '"/fablepowers:approve\'');
  assert.equal(stripWrappingQuotes('"'), '"');
  assert.equal(stripWrappingQuotes('/fablepowers:approve'), '/fablepowers:approve');
});

// --- integration: the real approval_gate.py, one per contract row (MF1) ---------------------------

test('after (write create) -> pending marker + notice appended to result.content', async () => {
  const { hook, repo } = await boot();
  const ev = await createSpec(hook, repo, 'docs/specs/2026-01-01-x.md');
  assert.ok(exists(fp(repo, '2026-01-01-x', 'pending')));
  const last = ev.result.content.at(-1);
  assert.equal(last.type, 'text');
  assert.match(last.text, /now pending the user's approval/);
  assert.equal(ev.result.content[0].text, 'Created file successfully: docs/specs/a.md');
  assert.equal(typeof ev.result.output, 'object', 'result.output untouched');
  assert.ok(!('fp' in ev.result.output));
});

test('after: overwrite, child-session and subdirectory-session writes do not pend; status error does nothing', async () => {
  const { hook, repo } = await boot();
  const over = fixture('after-write-root-overwrite', repo);
  await hook('tool.execute.after')(over);
  await createSpec(hook, repo, 'docs/specs/c.md', { sid: CHILD_SID });
  const sub = path.join(repo, 'sub');
  const { hook: hook2 } = await boot({}, { repo, sessions: { [ROOT_SID]: { id: ROOT_SID, location: { directory: sub } } } });
  await createSpec(hook2, repo, 'docs/specs/s.md', { dir: sub });
  const err = { tool: 'question', sessionID: ROOT_SID, id: 'c1', input: {}, status: 'error', error: { message: 'x' } };
  await hook('tool.execute.after')(err);
  assert.ok(!exists(path.join(repo, '.fablepowers')) || fs.readdirSync(path.join(repo, '.fablepowers')).every((k) => !exists(fp(repo, k, 'pending'))));
  assert.ok(!('result' in err));
});

test('permission edit while pending: outside the allowlist denied, inside untouched; marker denied always; adapter never allows', async () => {
  const { hook, repo } = await boot();
  const perm = hook('permission.evaluate');
  const m0 = permEdit(repo, '.fablepowers/k/approved');
  await perm(m0);
  assert.equal(m0.effect, 'deny', 'marker denied with nothing pending');
  assert.match(m0.message, /Approval markers/);
  const free = permEdit(repo, 'src/app.py');
  await perm(free);
  assert.equal(free.effect, 'ask', 'nothing pending: untouched');
  await createSpec(hook, repo, 'docs/specs/p.md');
  const src = permEdit(repo, 'src/app.py');
  await perm(src);
  assert.equal(src.effect, 'deny');
  assert.match(src.message, /only docs\/specs\/, docs\/plans\/ and \.fablepowers\/ are open/);
  for (const ok of ['docs/plans/plan.md', 'docs/specs/p.md']) {
    const e = permEdit(repo, ok);
    await perm(e);
    assert.equal(e.effect, 'ask', `${ok}: untouched (never set to allow)`);
    assert.ok(!('message' in e) || e.message === undefined);
  }
  const cfg = permEdit(repo, 'opencode.json');
  await perm(cfg);
  assert.equal(cfg.effect, 'deny', 'config guard');
  const child = permEdit(repo, 'src/x.py', CHILD_SID);
  await perm(child);
  assert.equal(child.effect, 'deny', 'child-session edit denied too');
  const plug = permEdit(repo, path.join(ROOT, 'hooks', 'approval_gate.py'));
  await perm(plug);
  assert.equal(plug.effect, 'deny', 'plugin root closed while pending (SF2)');
});

test('permission subagent while pending: implementer denied, reviewer/explore untouched; continuation judged by resources[0]', async () => {
  const { hook, repo } = await boot();
  const perm = hook('permission.evaluate');
  const pre = permSub(repo, 'fablepowers-implementer');
  await perm(pre);
  assert.equal(pre.effect, 'ask', 'nothing pending');
  await createSpec(hook, repo);
  for (const [agent, want] of [['fablepowers-implementer', 'deny'], ['fablepowers-strict-implementer', 'deny'], ['general', 'deny'], ['fablepowers-reviewer', 'ask'], ['explore', 'ask']]) {
    const e = permSub(repo, agent);
    await perm(e);
    assert.equal(e.effect, want, agent);
  }
  const cont = permSub(repo, 'fablepowers-implementer', 'permission-subagent-continuation');
  await perm(cont);
  assert.equal(cont.effect, 'deny', 'continuation as implementer');
  const contOk = fixture('permission-subagent-continuation', repo);
  contOk.effect = 'ask';
  await perm(contOk);
  assert.equal(contOk.effect, 'ask', 'continuation as explore (recorded payload)');
});

test('before subagent while pending: the gate deny throws (blocks); allowed agents do not', async () => {
  const { hook, repo } = await boot();
  await createSpec(hook, repo);
  const before = hook('tool.execute.before');
  const e = fixture('before-subagent-continuation', repo);
  e.input.agent = 'fablepowers-implementer';
  await assert.rejects(before(e), /awaits the user's approval/);
  const ok = fixture('before-subagent-continuation', repo);
  await before(ok); // explore
  const rv = fixture('before-subagent-root', repo);
  rv.input.agent = 'fablepowers-reviewer';
  await before(rv);
});

test('prompt approve (quoted, as opencode run sends it) -> approved; context appended to the prompt text', async () => {
  const { hook, repo } = await boot();
  await createSpec(hook, repo, 'docs/specs/q.md');
  const ev = { sessionID: ROOT_SID, prompt: { text: '"/fablepowers:approve"' } };
  await hook('session.prompt')(ev);
  assert.ok(exists(fp(repo, 'q', 'approved')));
  assert.ok(ev.prompt.text.startsWith('"/fablepowers:approve"\n\n'));
  assert.match(ev.prompt.text, /approval is recorded/);
  assert.match(ev.prompt.text, /fablepowers:implementation-plan/, 'SF11 next step');
  const after = permSub(repo, 'fablepowers-implementer');
  await hook('permission.evaluate')(after);
  assert.equal(after.effect, 'ask', 'approved: dispatch allowed');
});

test('prompt approve from a child session or an unknown-parent session records nothing (pending still created on unknown)', async () => {
  const { hook, repo } = await boot();
  await createSpec(hook, repo, 'docs/specs/k.md');
  const ev = fixture('prompt-child', repo);
  ev.prompt.text = '/fablepowers:approve';
  await hook('session.prompt')(ev);
  assert.ok(!exists(fp(repo, 'k', 'approved')));
  assert.match(ev.prompt.text, /recorded nothing/);
  // A plugin instance whose session lookups fail: SF9 pending yes, approval no.
  const repo2 = newRepo();
  const { hook: h2 } = await boot({}, { repo: repo2, getFails: true, locationDir: repo2 });
  await createSpec(h2, repo2, 'docs/specs/u.md');
  assert.ok(exists(fp(repo2, 'u', 'pending')), 'pending created on unknown parent');
  const ev2 = { sessionID: ROOT_SID, prompt: { text: '/fablepowers:approve' } };
  await h2('session.prompt')(ev2);
  assert.ok(!exists(fp(repo2, 'u', 'approved')), 'approve not recorded on unknown parent');
  assert.match(ev2.prompt.text, /main session/);
});

test('command approve / withdraw -> markers + synthetic message to the session', async () => {
  const { hook, ctx, repo } = await boot();
  await createSpec(hook, repo, 'docs/specs/c1.md');
  await createSpec(hook, repo, 'docs/specs/c2.md');
  const input = fixture('command-approve', repo);
  input.prompt.text = 'c1';
  await ctx.commands.get('fablepowers:approve').execute(input);
  assert.ok(exists(fp(repo, 'c1', 'approved')));
  assert.equal(ctx.synthetic.length, 1);
  assert.equal(ctx.synthetic[0].sessionID, SERVE_SID);
  assert.match(ctx.synthetic[0].text, /approved design `docs\/specs\/c1.md`/);
  await ctx.commands.get('fablepowers:withdraw').execute(fixture('command-withdraw', repo));
  assert.ok(!exists(fp(repo, 'c2', 'pending')));
  assert.match(ctx.synthetic[1].text, /withdrew design `docs\/specs\/c2.md`/);
});

test('command (N4, N-c): gate timeout, bad gate output or a plugin error -> a visible "may not have been recorded" message with the reason', async () => {
  const slow = fakePython({ sleep: 3, out: '{"context":"late"}' });
  const t = await boot({ env: envWith({ FABLEPOWERS_PYTHON: slow.python }), gateTimeoutMs: 300 });
  await t.ctx.commands.get('fablepowers:approve').execute(fixture('command-approve', t.repo));
  assert.equal(t.ctx.synthetic.length, 1);
  assert.equal(t.ctx.synthetic[0].sessionID, SERVE_SID);
  assert.match(t.ctx.synthetic[0].text, /`\/fablepowers:approve` may not have been recorded: the gate call timed out after 300 ms/);
  const bad = fakePython({ out: 'not json' });
  const b = await boot({ env: envWith({ FABLEPOWERS_PYTHON: bad.python }) });
  await b.ctx.commands.get('fablepowers:withdraw').execute(fixture('command-withdraw', b.repo));
  assert.match(b.ctx.synthetic[0].text, /`\/fablepowers:withdraw` may not have been recorded: the gate call returned no JSON object/);
  const empty = fakePython({ out: '{}' });
  const e = await boot({ env: envWith({ FABLEPOWERS_PYTHON: empty.python }) });
  await e.ctx.commands.get('fablepowers:approve').execute(fixture('command-approve', e.repo));
  assert.match(e.ctx.synthetic[0].text, /may not have been recorded: the gate gave no answer/);
  const { ctx, repo } = await boot();
  await ctx.commands.get('fablepowers:approve').execute(throwing(fixture('command-approve', repo), 'prompt'));
  assert.match(ctx.synthetic[0].text, /may not have been recorded: the plugin hit an error \(boom prompt\)/);
  // No session directory at all (lookup failed, no ctx.location): said so, not silent.
  const nd = fakeCtx({ repo: newRepo(), getFails: true });
  nd.location = {};
  await createPlugin({ env: envWith() }).setup(nd);
  await nd.commands.get('fablepowers:approve').execute(fixture('command-approve', '/x'));
  assert.match(nd.synthetic[0].text, /`\/fablepowers:approve` was not recorded: the session directory is unknown/);
});

test('command (N-c): posting the message itself throws -> logged in the session repo, not ctx.location', async () => {
  const { ctx, repo } = await boot({}, { locationDir: newRepo() });
  ctx.session.synthetic = async () => { throw new Error('post failed'); };
  await ctx.commands.get('fablepowers:approve').execute(fixture('command-approve', repo));
  assert.match(readLog(repo), /opencode plugin: command approve message failed, allowed: Error: post failed/);
  assert.equal(readLog(ctx.location.directory), '');
});

test('command (N4): no sessionID -> nothing recorded, the command fails with a visible reason; logged', async () => {
  const r = newRepo();
  const { hook, ctx, repo } = await boot({}, { repo: r, locationDir: r });
  await createSpec(hook, repo, 'docs/specs/ns.md');
  const input = fixture('command-approve', repo);
  delete input.sessionID;
  input.prompt.text = 'ns';
  await assert.rejects(ctx.commands.get('fablepowers:approve').execute(input), /`\/fablepowers:approve` was not recorded: the command arrived without a session id/);
  assert.ok(!exists(fp(repo, 'ns', 'approved')));
  assert.equal(ctx.synthetic.length, 0);
  assert.match(readLog(repo), /command approve without a sessionID; nothing recorded/);
});

test('question path: Approve answer to the two-option question -> approved via question; context appended', async () => {
  const { hook, repo } = await boot();
  await createSpec(hook, repo, 'docs/specs/qq.md');
  const ev = fixture('after-question-root-approve', repo);
  await hook('tool.execute.after')(ev);
  const a = JSON.parse(fs.readFileSync(fp(repo, 'qq', 'approved'), 'utf8'));
  assert.equal(a.via, 'question');
  assert.match(ev.result.content.at(-1).text, /the user approved design/);
});

test('patch adds (C12): existed stat in before, consumed in after; entry dropped on an error result', async () => {
  const { hook, repo } = await boot();
  const before = hook('tool.execute.before');
  const after = hook('tool.execute.after');
  const patchEv = (id, rel, status = 'completed') => ({
    tool: 'patch', sessionID: ROOT_SID, id, input: { patchText: `*** Begin Patch\n*** Add File: ${rel}\n+alpha\n*** End Patch` },
    status, ...(status === 'completed'
      ? { result: { output: { applied: [{ type: 'add', resource: rel, target: path.join(repo, rel) }], files: [] }, content: [{ type: 'text', text: 'Success.' }] } }
      : { error: { message: 'denied' } }),
  });
  // new file: pending
  await before(patchEv('call_new', 'docs/specs/new.md'));
  fs.writeFileSync(path.join(repo, 'docs/specs/new.md'), 'alpha\n');
  await after(patchEv('call_new', 'docs/specs/new.md'));
  assert.ok(exists(fp(repo, 'new', 'pending')));
  // existing file: no pending
  fs.writeFileSync(path.join(repo, 'docs/specs/old.md'), 'x\n');
  await before(patchEv('call_old', 'docs/specs/old.md'));
  await after(patchEv('call_old', 'docs/specs/old.md'));
  assert.ok(!exists(fp(repo, 'old')));
  // an errored call drops its record: a later completed after with the same id has none
  await before(patchEv('call_err', 'docs/specs/err.md'));
  await after(patchEv('call_err', 'docs/specs/err.md', 'error'));
  fs.writeFileSync(path.join(repo, 'docs/specs/err.md'), 'x\n');
  await after(patchEv('call_err', 'docs/specs/err.md'));
  assert.ok(!exists(fp(repo, 'err')), 'no existed record -> no pending');
  assert.match(readLog(repo), /without an existed record/);
});

test('patch (SF-B): symlinked session directory, OpenCode reports the realpath target -> pending', async () => {
  const real = newRepo();
  const link = path.join(tmpdir('lnk'), 'repo-link');
  fs.symlinkSync(real, link);
  const { hook } = await boot({}, { repo: link });
  const rel = 'docs/specs/sl.md';
  const ev = (status) => ({
    tool: 'patch', sessionID: ROOT_SID, id: 'call_sl', input: { patchText: `*** Begin Patch\n*** Add File: ${rel}\n+alpha\n*** End Patch` },
    status, result: { output: { applied: [{ type: 'add', resource: rel, target: path.join(real, rel) }], files: [] }, content: [] },
  });
  await hook('tool.execute.before')(ev('running'));
  fs.writeFileSync(path.join(real, rel), 'alpha\n');
  const after = ev('completed');
  await hook('tool.execute.after')(after);
  assert.ok(exists(fp(real, 'sl', 'pending')), readLog(real));
  assert.match(after.result.content.at(-1).text, /now pending/);
});

test('patch (N2): Update File + Move to docs/specs/<name>.md from a root session -> pending; from a child, not', async () => {
  const { hook, repo } = await boot();
  const mv = (sid, id, dest) => ({
    tool: 'patch', sessionID: sid, id,
    input: { patchText: `*** Begin Patch\n*** Update File: docs/plans/draft.md\n*** Move to: ${dest}\n@@\n-a\n+b\n*** End Patch` },
    status: 'completed', result: { output: { applied: [{ type: 'update', resource: dest, target: path.join(repo, dest) }], files: [] }, content: [] },
  });
  fs.writeFileSync(path.join(repo, 'docs/specs/moved.md'), 'b\n');
  const e = mv(ROOT_SID, 'call_mv', 'docs/specs/moved.md');
  await hook('tool.execute.before')(e);
  await hook('tool.execute.after')(e);
  assert.ok(exists(fp(repo, 'moved', 'pending')));
  assert.match(e.result.content.at(-1).text, /now pending/);
  fs.writeFileSync(path.join(repo, 'docs/specs/moved2.md'), 'b\n');
  const c = mv(CHILD_SID, 'call_mv2', 'docs/specs/moved2.md');
  await hook('tool.execute.after')(c);
  assert.ok(!exists(fp(repo, 'moved2')));
});

// --- fail open ------------------------------------------------------------------------------------

function throwing(base, key) {
  return new Proxy(base, { get(t, k) { if (k === key) throw new Error(`boom ${key}`); return t[k]; } });
}

test('a JS exception inside any hook body fails open (no throw, event untouched) and is logged', async () => {
  const { hook, ctx, repo } = await boot();
  await createSpec(hook, repo, 'docs/specs/f.md');
  const perm = permEdit(repo, 'src/app.py');
  const p = throwing(perm, 'metadata');
  await hook('permission.evaluate')(p);
  assert.equal(perm.effect, 'ask');
  await hook('tool.execute.before')(throwing(fixture('before-subagent-root', repo), 'input'));
  const af = fixture('after-write-root-created', repo);
  await hook('tool.execute.after')(throwing(af, 'result'));
  await hook('session.prompt')(throwing({ sessionID: ROOT_SID, prompt: { text: '/fablepowers:approve' } }, 'prompt'));
  await hook('session.context')(throwing({ sessionID: ROOT_SID, messages: [] }, 'messages'));
  await ctx.commands.get('fablepowers:approve').execute(throwing(fixture('command-approve', repo), 'prompt'));
  const log = readLog(repo);
  for (const w of ['permission.evaluate', 'tool.execute.before', 'tool.execute.after', 'prompt', 'context', 'command approve']) {
    assert.ok(log.includes(`opencode plugin: ${w} failed, allowed`), `${w} logged`);
  }
  assert.ok(!exists(fp(repo, 'f', 'approved')));
});

test('gate timeout (2 s default; 300 ms here) fails open and logs', async () => {
  const fake = fakePython({ sleep: 3, out: '{"decision":"deny","reason":"late"}' });
  const { hook, repo } = await boot({ env: envWith({ FABLEPOWERS_PYTHON: fake.python }), gateTimeoutMs: 300 });
  const e = permEdit(repo, 'src/app.py');
  const t0 = Date.now();
  await hook('permission.evaluate')(e);
  assert.ok(Date.now() - t0 < 2000);
  assert.equal(e.effect, 'ask');
  assert.match(readLog(repo), /gate call \(permission\) timed out after 300 ms; allowed/);
});

test('gate output that is not a JSON object, or a non-zero exit, fails open', async () => {
  for (const f of [{ out: 'not json' }, { out: '{"decision":"deny","reason":"x"}', exit: 1 }]) {
    const fake = fakePython(f);
    const { hook, repo } = await boot({ env: envWith({ FABLEPOWERS_PYTHON: fake.python }) });
    const e = permEdit(repo, 'src/app.py');
    await hook('permission.evaluate')(e);
    assert.equal(e.effect, 'ask');
    assert.match(readLog(repo), /allowed/);
  }
});

test('session-start timeout or bad output: bootstrap says unavailable, seats unpinned, map still there', async () => {
  const d = tmpdir('fakebash');
  const slow = path.join(d, 'slow'); fs.writeFileSync(slow, '#!/bin/sh\nsleep 3\n'); fs.chmodSync(slow, 0o755);
  const bad = path.join(d, 'bad'); fs.writeFileSync(bad, '#!/bin/sh\necho nope\n'); fs.chmodSync(bad, 0o755);
  const h = home('[opencode]\nimplementer = "opencode/big-pickle"\n');
  for (const [b, why] of [[slow, /timed out after 300 ms/], [bad, /not the expected JSON/]]) {
    const { hook, ctx, repo } = await boot({ env: { ...BASE_ENV, HOME: h, FABLEPOWERS_BASH: b }, startTimeoutMs: 300 });
    const ev = ctxEvent(repo, ROOT_SID, [userMsg('hi')]);
    await hook('session.context')(ev);
    const t = ev.messages[0].content[0].text;
    assert.match(t, /fablepowers bootstrap unavailable: hooks\/session-start failed/);
    assert.match(t, why);
    assert.ok(t.includes('# Workflow Map'));
    assert.equal(ctx.agents.get('fablepowers-implementer').model, undefined);
  }
});

test('C6: no python -> bootstrap says the gate is off; hooks no-op; command posts the disabled notice', async () => {
  const { hook, ctx, repo } = await boot({ env: envWith({ FABLEPOWERS_PYTHON: '/nonexistent/python3' }) });
  const ev = ctxEvent(repo, ROOT_SID, [userMsg('hi')]);
  await hook('session.context')(ev);
  assert.match(ev.messages[0].content[0].text, /fablepowers approval gate disabled: python3 not found/);
  await createSpec(hook, repo, 'docs/specs/np.md');
  assert.ok(!exists(fp(repo, 'np')));
  const m = permEdit(repo, '.fablepowers/k/approved');
  await hook('permission.evaluate')(m);
  assert.equal(m.effect, 'ask');
  await ctx.commands.get('fablepowers:approve').execute(fixture('command-approve', repo));
  assert.match(ctx.synthetic[0].text, /python3 not found/);
  const pr = { sessionID: ROOT_SID, prompt: { text: '/fablepowers:approve' } };
  await hook('session.prompt')(pr);
  assert.match(pr.prompt.text, /python3 not found/);
});

test('C6: no bash -> short line + the workflow map read by JS; the gate still runs', async () => {
  assert.ok(REAL_PYTHON, 'a python3 is needed for this test');
  const { hook, repo } = await boot({ env: { ...BASE_ENV, HOME: home(), PATH: '/nonexistent', FABLEPOWERS_PYTHON: REAL_PYTHON }, bashFallbacks: [] });
  const ev = ctxEvent(repo, ROOT_SID, [userMsg('hi')]);
  await hook('session.context')(ev);
  const t = ev.messages[0].content[0].text;
  assert.match(t, /fablepowers bootstrap unavailable: bash not found/);
  assert.ok(t.includes('# Workflow Map'));
  assert.ok(!t.includes('approval gate disabled'));
  await createSpec(hook, repo, 'docs/specs/nb.md');
  assert.ok(exists(fp(repo, 'nb', 'pending')));
});

// --- packaging --------------------------------------------------------------------------------------

test('npm pack --dry-run lists exactly the intended files', { skip: spawnSync('npm', ['--version']).status !== 0 && 'npm not installed' }, () => {
  const r = spawnSync('npm', ['pack', '--dry-run', '--json', '--ignore-scripts'], { cwd: ROOT, encoding: 'utf8', env: { ...BASE_ENV, npm_config_loglevel: 'silent' } });
  assert.equal(r.status, 0, r.stderr);
  const got = JSON.parse(r.stdout)[0].files.map((f) => f.path).sort();
  const git = spawnSync('git', ['ls-files', '--', 'agents', 'skills', 'opencode', 'pi'], { cwd: ROOT, encoding: 'utf8' }).stdout.split('\n').filter(Boolean);
  const want = [...git, 'opencode/index.js', 'index.js', 'package.json', 'README.md', 'LICENSE', 'NOTICE', 'hooks/session-start', 'hooks/approval_gate.py'].sort();
  assert.deepEqual(got, [...new Set(want)].sort());
  const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
  assert.equal(pkg.version, '0.7.0');
  assert.equal(pkg.type, 'module');
  assert.equal(pkg.main, 'opencode/index.js');
});

test('version parity: package.json, both .claude-plugin manifests and the CHANGELOG head agree', () => {
  const read = (...p) => JSON.parse(fs.readFileSync(path.join(ROOT, ...p), 'utf8'));
  const pkg = read('package.json').version;
  const plugin = read('.claude-plugin', 'plugin.json').version;
  const market = read('.claude-plugin', 'marketplace.json').plugins.filter((p) => p.name === 'fablepowers');
  const head = /^## (\S+)/m.exec(fs.readFileSync(path.join(ROOT, 'CHANGELOG.md'), 'utf8'));
  assert.match(pkg, /^\d+\.\d+\.\d+$/);
  assert.equal(plugin, pkg, '.claude-plugin/plugin.json version');
  assert.equal(market.length, 1, 'one fablepowers entry in marketplace.json');
  assert.equal(market[0].version, pkg, '.claude-plugin/marketplace.json version');
  assert.ok(head, 'CHANGELOG.md has a version heading');
  assert.equal(head[1], pkg, 'newest CHANGELOG.md heading');
});

test('root index.js re-exports the plugin (local-directory form)', async () => {
  const m = await import(path.join(ROOT, 'index.js'));
  const o = await import(path.join(ROOT, 'opencode', 'index.js'));
  assert.equal(m.default, o.default);
  assert.equal(m.default.id, 'fablepowers');
  assert.equal(typeof m.default.setup, 'function');
});
