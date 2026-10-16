// fablepowers plugin for OpenCode 2.0.x (default export `{ id, setup }`).
//
// An adapter: every gate decision and marker write stays in
// hooks/approval_gate.py, every seat/model parse in hooks/session-start
// (`--opencode` mode, JSON out). This file registers the skills, the seat
// agents and the approve/withdraw commands, injects the bootstrap into root
// sessions, and turns OpenCode hook events into `harness: "opencode"` gate
// payloads (the plan's gate payload contract).
//
// Rules this file keeps:
// - `node:` builtins only (OpenCode runs plugins under Bun).
// - Every hook body is wrapped in try/catch and fails OPEN (OpenCode fails
//   closed on a thrown hook error); the only blocking outcomes are the gate's
//   explicit denies (permission `effect = "deny"`, a throw from
//   tool.execute.before). The adapter never sets an allow.
// - Gate calls time out after 2 s, session-start after 3 s; a timeout or any
//   error is a no-op, logged to <toplevel>/.fablepowers/gate.log when the
//   toplevel is known.
// - Seats are read once at setup (agents register once per server start) and
//   cached; the bootstrap shows the same table.
// - No process-global state: OpenCode creates one plugin instance per
//   location (directory) in one server process, so all state is per instance.

import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const DEFAULT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const SEATS = {
  implementer: { agent: 'fablepowers-implementer', file: 'implementer.md' },
  strict_implementer: { agent: 'fablepowers-strict-implementer', file: 'strict-implementer.md' },
  reviewer: { agent: 'fablepowers-reviewer', file: 'reviewer.md' },
};
const USER_ONLY_SKILLS = new Set(['approve', 'withdraw']);
const GATE_TOOLS_AFTER = new Set(['write', 'edit', 'patch', 'question']);
const PY_FALLBACKS = ['/usr/bin/python3', '/usr/local/bin/python3', '/opt/homebrew/bin/python3'];
const BASH_FALLBACKS = ['/bin/bash', '/usr/bin/bash', '/usr/local/bin/bash', '/opt/homebrew/bin/bash'];
const BOOTSTRAP_TAG = 'fablepowers-bootstrap';
const SESSION_CACHE_MAX = 512;
const EXISTED_MAX = 256;
const COMMAND_TEXT = /\/fablepowers:(approve|withdraw)/;

// --- small helpers -----------------------------------------------------------------

function stripFrontmatter(text) {
  const m = /^﻿?---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(text);
  if (!m) return { meta: {}, body: text };
  const meta = {};
  for (const raw of m[1].split('\n')) {
    const line = raw.replace(/\r$/, '');
    const i = line.indexOf(':');
    if (i > 0 && !/^\s/.test(line)) {
      meta[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^(["'])([\s\S]*)\1$/, '$2');
    }
  }
  return { meta, body: m[2] };
}

// One wrapping pair of quotes (`opencode run "<text with spaces>"` adds it).
function stripWrappingQuotes(text) {
  const m = /^(["'])([\s\S]*)\1$/.exec(text);
  return m && text.length >= 2 ? m[2] : text;
}

function isExecutableFile(p) {
  try {
    const st = fs.statSync(p);
    if (!st.isFile()) return false;
    fs.accessSync(p, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function onPath(cmd, env) {
  for (const d of String(env.PATH || '').split(path.delimiter)) {
    if (!d || !path.isAbsolute(d)) continue;
    const p = path.join(d, cmd);
    if (isExecutableFile(p)) return p;
  }
  return null;
}

// The launcher's python search: $FABLEPOWERS_PYTHON as the only candidate when
// set, else python3 on PATH, then the absolute fallbacks; Python 3.8+ (-I).
function findPython(env, fallbacks = PY_FALLBACKS) {
  const cands = env.FABLEPOWERS_PYTHON ? [env.FABLEPOWERS_PYTHON] : [onPath('python3', env), ...fallbacks];
  for (const c of cands) {
    if (!c || !isExecutableFile(c)) continue;
    try {
      const r = spawnSync(c, ['-I', '-c', 'import sys; sys.exit(sys.version_info < (3, 8))'],
        { stdio: 'ignore', timeout: 3000, env });
      if (r.status === 0) return c;
    } catch { /* next candidate */ }
  }
  return null;
}

// bash for session-start: $FABLEPOWERS_BASH, then PATH, then the absolute fallbacks.
function findBash(env, fallbacks = BASH_FALLBACKS) {
  const cands = [env.FABLEPOWERS_BASH, onPath('bash', env), ...fallbacks];
  for (const c of cands) if (c && isExecutableFile(c)) return c;
  return null;
}

function findToplevel(dir) {
  if (typeof dir !== 'string' || !path.isAbsolute(dir)) return null;
  let d;
  try { d = fs.realpathSync(dir); } catch { d = path.resolve(dir); }
  for (;;) {
    try { fs.lstatSync(path.join(d, '.git')); return d; } catch { /* go up */ }
    const parent = path.dirname(d);
    if (parent === d) return null;
    d = parent;
  }
}

// Run `cmd args` with `input` on stdin; resolves {ok, stdout, why}. Never rejects.
function run(cmd, args, { input, timeoutMs, env }) {
  return new Promise((resolve) => {
    let done = false;
    let stdout = '';
    let child;
    const finish = (r) => { if (!done) { done = true; clearTimeout(timer); resolve(r); } };
    const timer = setTimeout(() => {
      try { child && child.kill('SIGKILL'); } catch { /* gone */ }
      finish({ ok: false, why: `timed out after ${timeoutMs} ms` });
    }, timeoutMs);
    try {
      child = spawn(cmd, args, { env, stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'ignore'] });
    } catch (e) {
      finish({ ok: false, why: `could not start ${cmd}: ${e && e.message}` });
      return;
    }
    child.on('error', (e) => finish({ ok: false, why: `could not run ${cmd}: ${e && e.message}` }));
    child.stdout.on('data', (b) => { stdout += b; });
    child.on('close', (code) => finish(code === 0 ? { ok: true, stdout } : { ok: false, why: `exit ${code}`, stdout }));
    if (input !== undefined) {
      child.stdin.on('error', () => { /* child gone early */ });
      child.stdin.end(input);
    }
  });
}

function parseObject(text) {
  try {
    const v = JSON.parse(text);
    return v && typeof v === 'object' && !Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
}

// --- the plugin ----------------------------------------------------------------------

// createPlugin(options) -> { id, setup }. Options (all optional; the test seam):
// root (plugin root), env (environment for discovery and child processes),
// gateTimeoutMs (2000), startTimeoutMs (3000), pythonFallbacks, bashFallbacks.
export function createPlugin(options = {}) {
  const ROOT = options.root || DEFAULT_ROOT;
  const gateTimeoutMs = options.gateTimeoutMs ?? 2000;
  const startTimeoutMs = options.startTimeoutMs ?? 3000;
  const setupDone = new WeakSet();

  async function setup(ctx) {
    if (!ctx || typeof ctx !== 'object' || setupDone.has(ctx)) return;
    setupDone.add(ctx);
    const env = options.env || process.env;
    const locationDir = typeof ctx.location?.directory === 'string' ? ctx.location.directory : null;

    const logLine = (top, line) => {
      if (!top) return;
      try {
        const d = path.join(top, '.fablepowers');
        fs.mkdirSync(d, { recursive: true });
        const gi = path.join(d, '.gitignore');
        if (!fs.existsSync(gi)) fs.writeFileSync(gi, '*\n');
        fs.appendFileSync(path.join(d, 'gate.log'),
          `${new Date().toISOString().replace(/\.\d+Z$/, 'Z')} opencode plugin: ${String(line).replace(/\n/g, ' | ')}\n`);
      } catch { /* logging never fails a hook */ }
    };
    const logAt = (dir, line) => logLine(findToplevel(dir), line);
    const report = (where, dir, e) => {
      logAt(dir || locationDir, `${where} failed, allowed: ${e && e.stack ? e.stack.split('\n').slice(0, 3).join(' | ') : e}`);
    };

    // python (C6) and the seat table + bootstrap (C1, C2, C7), once per instance.
    let python = null;
    try { python = findPython(env, options.pythonFallbacks); } catch { python = null; }

    let mapText = '';
    try {
      mapText = stripFrontmatter(fs.readFileSync(path.join(ROOT, 'skills', 'workflow', 'SKILL.md'), 'utf8')).body;
    } catch { mapText = ''; }

    let seats = { implementer: null, strict_implementer: null, reviewer: null };
    let context = null;
    const notes = [];
    const bash = findBash(env, options.bashFallbacks);
    if (!bash) {
      notes.push(`fablepowers bootstrap unavailable: bash not found. Plugin root: \`${ROOT}\`; every seat runs on the session model.`);
    } else {
      const r = await run(bash, [path.join(ROOT, 'hooks', 'session-start'), '--opencode'],
        { timeoutMs: startTimeoutMs, env });
      const out = r.ok ? parseObject(r.stdout) : null;
      if (out && typeof out.context === 'string' && out.seats && typeof out.seats === 'object') {
        context = out.context;
        for (const k of Object.keys(seats)) {
          const s = out.seats[k];
          if (s && typeof s.providerID === 'string' && s.providerID && typeof s.id === 'string' && s.id) {
            seats[k] = { providerID: s.providerID, id: s.id, variant: typeof s.variant === 'string' && s.variant ? s.variant : null };
          }
        }
      } else {
        const why = r.ok ? 'its output was not the expected JSON' : r.why;
        notes.push(`fablepowers bootstrap unavailable: hooks/session-start failed (${why}). Plugin root: \`${ROOT}\`; every seat runs on the session model.`);
        logAt(locationDir, `session-start --opencode failed (${why}); bootstrap without the seat table`);
      }
    }
    if (!python) notes.unshift('fablepowers approval gate disabled: python3 not found (install Python 3.8+ or set FABLEPOWERS_PYTHON in the OpenCode server environment, then restart OpenCode).');
    const bootstrapBody = context !== null
      ? [...notes, context].join('\n\n')
      : [...notes, mapText].filter(Boolean).join('\n\n');
    const bootstrap = `<${BOOTSTRAP_TAG}>\n${bootstrapBody}\n</${BOOTSTRAP_TAG}>`;
    const seatByAgent = new Map(Object.entries(SEATS).map(([k, v]) => [v.agent, k]));

    // --- session lookups (cwd, parent) --------------------------------------------
    const sessions = new Map();
    async function sessionInfo(sid) {
      if (typeof sid === 'string' && sessions.has(sid)) return sessions.get(sid);
      const fallback = { dir: locationDir, parentID: null, unknown: true };
      if (typeof sid !== 'string' || !sid || typeof ctx.session?.get !== 'function') return fallback;
      let rec;
      try { rec = await ctx.session.get({ sessionID: sid }); } catch { return fallback; }
      if (!rec || typeof rec !== 'object' || (rec.id !== undefined && rec.id !== sid)) return fallback;
      if (rec.parentID !== undefined && rec.parentID !== null && (typeof rec.parentID !== 'string' || !rec.parentID)) return fallback;
      const d = rec.location?.directory;
      const info = {
        dir: typeof d === 'string' && path.isAbsolute(d) ? d : locationDir,
        parentID: typeof rec.parentID === 'string' ? rec.parentID : null,
        unknown: false,
      };
      if (sessions.size >= SESSION_CACHE_MAX) {
        let drop = Math.ceil(SESSION_CACHE_MAX / 4);
        for (const k of sessions.keys()) { if (drop-- <= 0) break; sessions.delete(k); }
      }
      sessions.set(sid, info);
      return info;
    }

    // --- the gate call ---------------------------------------------------------------
    async function gate(hook, sid, fields) {
      const info = await sessionInfo(sid);
      if (!python || !info.dir) return {};
      const payload = {
        harness: 'opencode', hook, cwd: info.dir, session_id: sid ?? null,
        parent_id: info.parentID, plugin_root: ROOT, ...fields,
      };
      if (info.unknown) payload.parent_unknown = true;
      const r = await run(python, ['-I', path.join(ROOT, 'hooks', 'approval_gate.py')],
        { input: JSON.stringify(payload), timeoutMs: gateTimeoutMs, env });
      const out = r.ok ? parseObject(r.stdout) : null;
      if (!out) {
        logAt(info.dir, `gate call (${hook}) ${r.ok ? 'returned no JSON object' : r.why}; allowed`);
        return {};
      }
      return out;
    }

    // --- registration ----------------------------------------------------------------
    const guard = async (where, fn) => { try { await fn(); } catch (e) { report(where, null, e); } };

    await guard('skill registration', async () => {
      const skills = [];
      const dir = path.join(ROOT, 'skills');
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        if (!ent.isDirectory() || ent.name.startsWith('.') || USER_ONLY_SKILLS.has(ent.name)) continue;
        const p = path.join(dir, ent.name, 'SKILL.md');
        let text;
        try { text = fs.readFileSync(p, 'utf8'); } catch { continue; }
        const { meta, body } = stripFrontmatter(text);
        const id = `fablepowers:${ent.name}`;
        skills.push({ id, name: id, ...(meta.description ? { description: meta.description } : {}), path: p, content: body });
      }
      await ctx.skill.transform((d) => {
        for (const s of skills) {
          try {
            d.add(s);
          } catch (e) { report(`skill ${s.id}`, null, e); }
        }
      });
    });

    await guard('agent registration', async () => {
      // Each seat's role prompt is inlined into its system text (read once here), so a
      // seat needs no read outside the project and gets no external_directory grant.
      // A missing or unreadable role file falls back to a pointer (fail open, logged).
      const descs = {};
      const bodies = {};
      for (const [k, v] of Object.entries(SEATS)) {
        const role = path.join(ROOT, 'agents', v.file);
        try {
          const { meta, body } = stripFrontmatter(fs.readFileSync(role, 'utf8'));
          descs[k] = meta.description || '';
          bodies[k] = body.trim() ? body.trim() : null;
          if (!bodies[k]) logAt(locationDir, `seat ${v.agent}: role file ${role} has an empty body; system prompt points at the file instead`);
        } catch (e) {
          descs[k] = '';
          bodies[k] = null;
          logAt(locationDir, `seat ${v.agent}: could not read role file ${role} (${e && e.code ? e.code : e}); system prompt points at the file instead`);
        }
      }
      await ctx.agent.transform((d) => {
        for (const [k, v] of Object.entries(SEATS)) {
          try {
            d.update(v.agent, (a) => {
              const role = path.join(ROOT, 'agents', v.file);
              a.mode = 'subagent';
              a.description = descs[k] || `fablepowers ${k} seat.`;
              const head = `You are the fablepowers ${k.replace('_', '-')} agent (\`${v.agent}\`). Plugin root: \`${ROOT}\`; fablepowers skills load through the skill tool as \`fablepowers:<name>\`. You cannot dispatch subagents.`;
              a.system = bodies[k]
                ? `${head}\nYour role instructions follow (source: \`${role}\`).\n\n${bodies[k]}`
                : `${head}\nYour role instructions are in \`${role}\`: read that file first and follow it.`;
              const perms = Array.isArray(a.permissions) ? a.permissions : [];
              const deny = { action: 'subagent', resource: '*', effect: 'deny' };
              if (!perms.some((p) => p && p.action === deny.action && p.resource === deny.resource && p.effect === deny.effect)) perms.push(deny);
              a.permissions = perms;
              const seat = seats[k];
              if (seat) a.model = { providerID: seat.providerID, id: seat.id, ...(seat.variant ? { variant: seat.variant } : {}) };
            });
          } catch (e) { report(`agent ${v.agent}`, null, e); }
        }
      });
    });

    const commandFor = (verb) => ({
      name: `fablepowers:${verb}`,
      description: verb === 'approve'
        ? 'Record your approval of the pending design (/fablepowers:approve [spec key or path]).'
        : 'Withdraw a pending design you abandoned (/fablepowers:withdraw [spec key or path]).',
      execute: async (input) => {
        const sid = input?.sessionID;
        let text = null;
        try {
          if (!python) {
            text = `fablepowers approval gate disabled: python3 not found, so \`/fablepowers:${verb}\` recorded nothing. Tell the user to install Python 3.8+ (or set FABLEPOWERS_PYTHON) and restart OpenCode.`;
          } else {
            const args = typeof input?.prompt?.text === 'string' ? input.prompt.text : '';
            const out = await gate('command', sid, { verb, args });
            if (typeof out.context === 'string' && out.context) text = out.context;
          }
          if (text && sid && typeof ctx.session?.synthetic === 'function') {
            await ctx.session.synthetic({ sessionID: sid, text });
          }
        } catch (e) {
          let dir = null;
          try { dir = (await sessionInfo(sid)).dir; } catch { /* none */ }
          report(`command ${verb}`, dir, e);
        }
      },
    });
    await guard('command registration', async () => {
      await ctx.command.transform((d) => {
        for (const verb of ['approve', 'withdraw']) {
          try {
            d.add(commandFor(verb));
          } catch (e) { report(`command fablepowers:${verb}`, null, e); }
        }
      });
    });

    // --- hooks -----------------------------------------------------------------------
    // Each body fails open: an exception is logged and the event is left untouched.
    const wrap = (where, fn) => async (ev) => {
      try { await fn(ev); } catch (e) {
        let dir = null;
        try { dir = (await sessionInfo(ev?.sessionID)).dir; } catch { /* none */ }
        report(where, dir, e);
      }
    };

    await guard('permission hook', () => ctx.permission.hook('evaluate', wrap('permission.evaluate', async (ev) => {
      if (ev.action !== 'edit' && ev.action !== 'subagent') return;
      const files = Array.isArray(ev.metadata?.files) ? ev.metadata.files : [];
      const out = await gate('permission', ev.sessionID, {
        action: ev.action, resources: Array.isArray(ev.resources) ? ev.resources : [], files,
      });
      if (out.decision === 'deny' && typeof out.reason === 'string' && out.reason) {
        ev.effect = 'deny';
        ev.message = out.reason;
      }
    })));

    const existed = new Map(); // call id -> {path: existed-before} for patch adds (C12)
    await guard('execute.before hook', () => ctx.tool.hook('execute.before', async (ev) => {
      let denyReason = null;
      try {
        const input = ev.input && typeof ev.input === 'object' ? ev.input : null;
        if (ev.tool === 'subagent' && input) {
          const seat = seatByAgent.get(input.agent);
          if (seat && seats[seat] && 'model' in input) delete input.model;
          const out = await gate('before', ev.sessionID, { tool: ev.tool, input, existed: {} });
          if (out.decision === 'deny' && typeof out.reason === 'string' && out.reason) denyReason = out.reason;
        } else if (ev.tool === 'patch' && input && typeof ev.id === 'string') {
          const info = await sessionInfo(ev.sessionID);
          const text = typeof input.patchText === 'string' ? input.patchText : '';
          const map = {};
          for (const m of text.matchAll(/^[ \t]*\*\*\*[ \t]*Add File[ \t]*:[ \t]*(.+?)[ \t]*\r?$/gim)) {
            const rel = m[1];
            const abs = path.isAbsolute(rel) ? rel : (info.dir ? path.join(info.dir, rel) : null);
            if (!abs) continue;
            let ex = true;
            try { fs.lstatSync(abs); } catch (e) { ex = !(e && e.code === 'ENOENT'); }
            map[rel] = ex;
          }
          if (existed.size >= EXISTED_MAX) existed.delete(existed.keys().next().value);
          existed.set(ev.id, map);
        }
      } catch (e) {
        let dir = null;
        try { dir = (await sessionInfo(ev?.sessionID)).dir; } catch { /* none */ }
        report('tool.execute.before', dir, e);
        return;
      }
      if (denyReason) throw new Error(denyReason);
    }));

    await guard('execute.after hook', () => ctx.tool.hook('execute.after', wrap('tool.execute.after', async (ev) => {
      const ex = typeof ev.id === 'string' ? existed.get(ev.id) : undefined;
      if (typeof ev.id === 'string') existed.delete(ev.id);
      if (ev.status !== 'completed' || !ev.result || typeof ev.result !== 'object') return;
      if (!GATE_TOOLS_AFTER.has(ev.tool)) return;
      const out = await gate('after', ev.sessionID, {
        tool: ev.tool, input: ev.input ?? null, status: ev.status, output: ev.result.output ?? null,
        existed: ex || {},
      });
      if (typeof out.context === 'string' && out.context) {
        if (!Array.isArray(ev.result.content)) ev.result.content = [];
        ev.result.content.push({ type: 'text', text: out.context });
      }
    })));

    await guard('prompt hook', () => ctx.session.hook('prompt', wrap('prompt', async (ev) => {
      const text = ev.prompt?.text;
      if (typeof text !== 'string' || !COMMAND_TEXT.test(text)) return;
      let add = null;
      if (!python) {
        add = 'fablepowers approval gate disabled: python3 not found, so this recorded nothing. Tell the user to install Python 3.8+ (or set FABLEPOWERS_PYTHON) and restart OpenCode.';
      } else {
        const out = await gate('prompt', ev.sessionID, { text: stripWrappingQuotes(text) });
        if (typeof out.context === 'string' && out.context) add = out.context;
      }
      if (add) ev.prompt.text = `${text}\n\n${add}`;
    })));

    await guard('context hook', () => ctx.session.hook('context', wrap('context', async (ev) => {
      if (!Array.isArray(ev.messages)) return;
      const info = await sessionInfo(ev.sessionID);
      if (info.parentID) return; // root sessions only (a failed lookup injects)
      const has = (m) => (Array.isArray(m.content)
        ? m.content.some((p) => p && typeof p.text === 'string' && p.text.includes(`<${BOOTSTRAP_TAG}>`))
        : typeof m.content === 'string' && m.content.includes(`<${BOOTSTRAP_TAG}>`));
      if (ev.messages.some((m) => m && has(m))) return;
      const first = ev.messages.find((m) => m && m.role === 'user');
      const part = { type: 'text', text: bootstrap };
      if (!first) {
        // After compaction only a checkpoint may remain: append the bootstrap.
        ev.messages.push({ role: 'user', content: [part] });
      } else if (Array.isArray(first.content)) {
        first.content.unshift(part);
      } else {
        first.content = [part, ...(typeof first.content === 'string' && first.content ? [{ type: 'text', text: first.content }] : [])];
      }
    })));
  }

  return { id: 'fablepowers', setup };
}

// Helpers for the test suite (tests/opencode/plugin.test.mjs); not plugin API.
createPlugin.internals = { SEATS, BOOTSTRAP_TAG, stripFrontmatter, stripWrappingQuotes, findPython, findBash, findToplevel };

export default createPlugin();
