// fablepowers extension for Pi 1.x (@earendil-works/pi-coding-agent).
//
// An adapter, like opencode/index.js: every gate decision and marker write stays
// in hooks/approval_gate.py (`harness: "pi"` payloads), every seat/model parse in
// hooks/session-start (`--pi` mode, JSON out). This file adds:
// - the bootstrap: a `fablepowers_workflow` system-prompt section in root sessions;
// - `fablepowers_dispatch {seat, task, cwd?}`: runs a seat as a child `pi` process
//   (derived from Pi's MIT subagent example, examples/extensions/subagent/; see
//   NOTICE) on the seat's pinned model, with this extension loaded in the child;
// - `fablepowers_ask_approval {spec}`: the Approve / Changes needed dialog;
// - `/fablepowers:approve` and `/fablepowers:withdraw`;
// - the gate adapter on `tool_call` / `tool_result`.
//
// Rules this file keeps:
// - `node:` builtins only, plain JSON-schema tool parameters (no typebox), and
//   only erasable TypeScript (it runs under jiti in Pi and under `node --test`
//   type stripping in tests/pi/).
// - Every handler body is wrapped in try/catch and fails OPEN (Pi treats a
//   throwing handler as a block); the only blocks are the gate's explicit denies.
// - Gate calls time out after 2 s, session-start after 3 s; a timeout or error
//   is logged to <toplevel>/.fablepowers/gate.log.
// - One registration per session generation: a process-global guard under a
//   fixed Symbol (two copies at different paths would otherwise crash Pi with a
//   tool conflict), cleared in `session_shutdown`, which Pi fires before it
//   re-runs the factory on /new, /resume, /fork and /reload.
// - `session_start` handlers are idempotent (RPC fires it twice after a switch).
// - Command results go to the model with pi.sendMessage and to the user with
//   ctx.ui.notify (tui/rpc) or one stderr line (print/json); never stdout.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn as nodeSpawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SELF = fileURLToPath(import.meta.url);
const DEFAULT_ROOT = path.resolve(path.dirname(SELF), '..');
const GUARD = Symbol.for('fablepowers.pi.loaded');

const SEATS = { implementer: 'implementer.md', strict_implementer: 'strict-implementer.md', reviewer: 'reviewer.md' };
const THINKING_LEVELS = new Set(['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']);
const PY_FALLBACKS = ['/usr/bin/python3', '/usr/local/bin/python3', '/opt/homebrew/bin/python3'];
const BASH_FALLBACKS = ['/bin/bash', '/usr/bin/bash', '/usr/local/bin/bash', '/opt/homebrew/bin/bash'];
const CHILD_FLAG = 'fablepowers-child';
const SECTION = 'fablepowers_workflow';
const RESULT_TYPE = 'fablepowers-result';
const CHILD_ENTRY = 'fablepowers-child';
const OUTPUT_CAP = 50 * 1024;
const TASK_INLINE_MAX = 64 * 1024;
const STDERR_TAIL = 8 * 1024;
const LINE_MAX = 16 * 1024 * 1024;
const EXISTED_MAX = 256;
const GATE_FAILED = Symbol('fablepowers gate call failed');
const UNICODE_SPACES = /[  -   　]/g;

// --- small helpers (copied from opencode/index.js; SF6: no shared lib) ---------------

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
      try { if (child) child.kill('SIGKILL'); } catch { /* gone */ }
      finish({ ok: false, why: `timed out after ${timeoutMs} ms` });
    }, timeoutMs);
    try {
      child = nodeSpawn(cmd, args, { env, stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'ignore'] });
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

const under = (p, dir) => p === dir || p.startsWith(dir.endsWith(path.sep) ? dir : dir + path.sep);
const errText = (e) => (e && e.stack ? e.stack.split('\n').slice(0, 3).join(' | ') : String(e));

// --- Pi's path resolution (Q-G1) -----------------------------------------------------
// A copy of Pi 1.2.0's resolveToCwd (core/tools/path-utils.js -> utils/paths.js
// resolvePath with normalizeUnicodeSpaces and stripAtPrefix): unicode spaces to
// ' ', one leading '@' dropped, then '~' / '~/' expanded, then file:// URLs, then
// resolved against cwd (itself '~'-expanded). Pi's win32 shell-path conversion is
// left out (the gate is POSIX). A file:// URL Node cannot convert throws.
function normalizePiPath(input, { unicode = false, stripAt = false, home }) {
  let s = input;
  if (unicode) s = s.replace(UNICODE_SPACES, ' ');
  if (stripAt && s.startsWith('@')) s = s.slice(1);
  if (s === '~') return home;
  if (s.startsWith('~/')) return path.join(home, s.slice(2));
  if (/^file:\/\//.test(s)) return fileURLToPath(s);
  return s;
}

function resolveToCwd(filePath, cwd, home = os.homedir()) {
  const n = normalizePiPath(filePath, { unicode: true, stripAt: true, home });
  const base = normalizePiPath(cwd, { home });
  return path.isAbsolute(n) ? path.resolve(n) : path.resolve(base, n);
}

// The example's getPiInvocation (same executable and version as the parent),
// with argv[1] realpath'd: fnm and similar managers put a per-shell symlink there
// that can vanish while a long-lived parent runs (Task 0 item 2).
function piInvocationFor(args, { argv1 = process.argv[1], execPath = process.execPath } = {}) {
  const isBunVirtualScript = typeof argv1 === 'string' && argv1.startsWith('/$bunfs/root/');
  if (argv1 && !isBunVirtualScript && fs.existsSync(argv1)) {
    let script = argv1;
    try { script = fs.realpathSync(argv1); } catch { /* keep argv1 */ }
    return { command: execPath, args: [script, ...args] };
  }
  const execName = path.basename(execPath).toLowerCase();
  if (!/^(node|bun)(\.exe)?$/.test(execName)) return { command: execPath, args };
  return { command: 'pi', args };
}

// The output text capped at `cap` UTF-8 bytes, with a note naming what was dropped.
function capOutput(text, cap, where) {
  const bytes = Buffer.byteLength(text, 'utf8');
  if (bytes <= cap) return text;
  let cut = text.slice(0, cap);
  while (Buffer.byteLength(cut, 'utf8') > cap) cut = cut.slice(0, -1);
  const dropped = bytes - Buffer.byteLength(cut, 'utf8');
  return `${cut}\n\n[Output truncated: ${dropped} bytes omitted.${where ? ` The child's full transcript: ${where}` : ''}]`;
}

function lastText(message) {
  if (!message || !Array.isArray(message.content)) return '';
  return message.content.filter((p) => p && p.type === 'text' && typeof p.text === 'string').map((p) => p.text).join('\n');
}

// --- the extension -------------------------------------------------------------------

// createExtension(options) -> the Pi extension factory. Options (all optional; the
// test seam): root (plugin root), env, home, gateTimeoutMs (2000), startTimeoutMs
// (3000), killGraceMs (5000), watchdogMs (2000), exitGraceMs (3000), piInvocation
// (args -> {command, args}), spawn, tmpdir, getPpid, exit, stderr,
// pythonFallbacks, bashFallbacks.
export function createExtension(options = {}) {
  const ROOT = options.root || DEFAULT_ROOT;
  const env = options.env || process.env;
  const home = options.home || os.homedir();
  const gateTimeoutMs = options.gateTimeoutMs ?? 2000;
  const startTimeoutMs = options.startTimeoutMs ?? 3000;
  const killGraceMs = options.killGraceMs ?? 5000;
  const watchdogMs = options.watchdogMs ?? 2000;
  const exitGraceMs = options.exitGraceMs ?? 3000;
  const piInvocation = options.piInvocation || ((args) => piInvocationFor(args));
  const spawnFn = options.spawn || nodeSpawn;
  const tmpRoot = options.tmpdir || os.tmpdir();
  const getPpid = options.getPpid || (() => process.ppid);
  const exit = options.exit || ((code) => process.exit(code));
  const stderr = options.stderr || process.stderr;

  const logLine = (top, line) => {
    if (!top) return;
    try {
      const d = path.join(top, '.fablepowers');
      fs.mkdirSync(d, { recursive: true });
      const gi = path.join(d, '.gitignore');
      if (!fs.existsSync(gi)) fs.writeFileSync(gi, '*\n');
      fs.appendFileSync(path.join(d, 'gate.log'),
        `${new Date().toISOString().replace(/\.\d+Z$/, 'Z')} pi extension: ${String(line).replace(/\n/g, ' | ')}\n`);
    } catch { /* logging never fails a handler */ }
  };
  const logAt = (dir, line) => logLine(findToplevel(dir), line);

  return function fablepowers(pi) {
    // --- load-once guard (MF1 + Task 0 amendment) -------------------------------------
    const held = globalThis[GUARD];
    if (held) {
      logAt(process.cwd(), `duplicate fablepowers extension at ${ROOT} not registered; already loaded from ${held.owner}`);
      return;
    }
    const token = { owner: ROOT };
    globalThis[GUARD] = token;

    // --- per-generation state ----------------------------------------------------------
    let initPromise = null;
    let python = null;
    let seats = { implementer: null, strict_implementer: null, reviewer: null };
    let context = null;
    const startNotes = [];
    const existed = new Map(); // toolCallId -> the write target existed at tool_call
    const children = new Set(); // live child processes
    let watchdogStarted = false;
    let watchdogTimer = null;
    let childLogged = false;

    const report = (where, ctx, e) => {
      let cwd = null;
      try { cwd = ctx && typeof ctx.cwd === 'string' ? ctx.cwd : null; } catch { /* none */ }
      logAt(cwd || process.cwd(), `${where} failed, allowed: ${errText(e)}`);
    };

    function childState() {
      const envSet = typeof env.FABLEPOWERS_PARENT_SESSION === 'string' && env.FABLEPOWERS_PARENT_SESSION !== '';
      let flag;
      try { flag = pi.getFlag(CHILD_FLAG) === true; } catch { flag = null; }
      // Q-C1: a child only when BOTH are set; an unreadable flag is unknown (null),
      // which the gate's refusal rule treats as a child.
      return { envSet, flag, isChild: flag === null ? null : envSet && flag };
    }

    function init() {
      if (initPromise) return initPromise;
      initPromise = (async () => {
        try { python = findPython(env, options.pythonFallbacks); } catch { python = null; }
        const bash = findBash(env, options.bashFallbacks);
        if (!bash) {
          startNotes.push(`fablepowers bootstrap degraded: bash not found, so there is no seat table; every seat runs on the session model. Plugin root: \`${ROOT}\`.`);
          return;
        }
        const r = await run(bash, [path.join(ROOT, 'hooks', 'session-start'), '--pi'], { timeoutMs: startTimeoutMs, env });
        const out = r.ok ? parseObject(r.stdout) : null;
        if (out && typeof out.context === 'string' && out.seats && typeof out.seats === 'object') {
          context = out.context;
          for (const k of Object.keys(seats)) {
            const s = out.seats[k];
            if (s && typeof s.provider === 'string' && s.provider && typeof s.id === 'string' && s.id) {
              seats[k] = { provider: s.provider, id: s.id, thinking: THINKING_LEVELS.has(s.thinking) ? s.thinking : null };
            }
          }
        } else {
          const why = r.ok ? 'its output was not the expected JSON' : r.why;
          startNotes.push(`fablepowers bootstrap degraded: hooks/session-start failed (${why}), so there is no seat table; every seat runs on the session model. Plugin root: \`${ROOT}\`.`);
          logAt(process.cwd(), `session-start --pi failed (${why}); bootstrap without the seat table`);
        }
      })().catch((e) => { logAt(process.cwd(), `init failed: ${errText(e)}`); });
      return initPromise;
    }

    async function bootstrapText() {
      await init();
      const notes = [];
      if (!python) notes.push('fablepowers approval gate disabled: python3 not found (install Python 3.8+ or set FABLEPOWERS_PYTHON, then restart Pi).');
      notes.push(...startNotes);
      const st = childState();
      if (st.envSet && st.flag === false) notes.push('fablepowers: FABLEPOWERS_PARENT_SESSION is set but this Pi was not started with --fablepowers-child, so it runs as a root session.');
      let body = context;
      if (body === null) {
        try { body = stripFrontmatter(fs.readFileSync(path.join(ROOT, 'skills', 'workflow', 'SKILL.md'), 'utf8')).body.trim(); } catch { body = ''; }
      }
      return [...notes, body].filter(Boolean).join('\n\n');
    }

    function sessionId(ctx) {
      try {
        const id = ctx.sessionManager.getSessionId();
        return typeof id === 'string' && id ? id : null;
      } catch {
        return null;
      }
    }

    // --- the gate call -------------------------------------------------------------------
    async function gate(hook, ctx, fields) {
      await init();
      if (!python) return { [GATE_FAILED]: 'python3 was not found, so the approval gate is off' };
      const cwd = ctx && typeof ctx.cwd === 'string' ? ctx.cwd : null;
      const payload = {
        harness: 'pi', hook, cwd, session_id: sessionId(ctx), is_child: childState().isChild,
        plugin_root: ROOT, mode: ctx && typeof ctx.mode === 'string' ? ctx.mode : 'unknown',
        env_session: env.PI_SESSION_ID !== undefined, ...fields,
      };
      if (typeof env.PI_CODING_AGENT_DIR === 'string' && env.PI_CODING_AGENT_DIR) payload.pi_agent_dir = env.PI_CODING_AGENT_DIR;
      const r = await run(python, ['-I', path.join(ROOT, 'hooks', 'approval_gate.py')],
        { input: JSON.stringify(payload), timeoutMs: gateTimeoutMs, env });
      const out = r.ok ? parseObject(r.stdout) : null;
      if (!out) {
        const why = r.ok ? 'returned no JSON object' : r.why;
        logAt(cwd || process.cwd(), `gate call (${hook}) ${why}; allowed`);
        return { [GATE_FAILED]: `the gate call ${why}` };
      }
      return out;
    }

    const denyOf = (out) => (out && out.decision === 'deny' && typeof out.reason === 'string' && out.reason
      ? { block: true, reason: out.reason } : undefined);

    // Results of commands (SF8): the model gets a custom message, the user a notify
    // (tui/rpc) or a stderr line (print/json and anything unknown). Never stdout.
    function deliver(ctx, text, isError) {
      try {
        pi.sendMessage({ customType: RESULT_TYPE, content: text, display: true }, { triggerTurn: false });
      } catch (e) { report('command result message', ctx, e); }
      try {
        if (ctx && (ctx.mode === 'tui' || ctx.mode === 'rpc') && ctx.ui && typeof ctx.ui.notify === 'function') {
          ctx.ui.notify(text, isError ? 'error' : 'info');
        } else {
          stderr.write(`${text}\n`);
        }
      } catch (e) { report('command result notice', ctx, e); }
    }

    // --- child lifecycle (SF1) -----------------------------------------------------------
    const alive = (proc) => proc.exitCode === null && proc.signalCode === null;
    function terminate(proc) {
      if (!alive(proc)) return;
      try { proc.kill('SIGTERM'); } catch { /* gone */ }
      const t = setTimeout(() => {
        if (alive(proc)) { try { proc.kill('SIGKILL'); } catch { /* gone */ } }
      }, killGraceMs);
      if (t && typeof t.unref === 'function') t.unref();
    }

    function startWatchdog(ctx) {
      if (watchdogStarted) return;
      watchdogStarted = true;
      const envPid = Number(env.FABLEPOWERS_PARENT_PID);
      const start = getPpid();
      if (Number.isInteger(envPid) && envPid > 1 && start !== envPid) {
        logAt(ctx.cwd, `child watchdog: parent pid ${envPid} from the environment, but ppid is ${start}; watching ppid ${start}`);
      }
      const parentGone = () => {
        logAt(ctx.cwd, `child watchdog: the parent process is gone (ppid now ${getPpid()}); aborting this child run and exiting`);
        try { ctx.abort(); } catch { /* none */ }
        try { ctx.shutdown(); } catch { /* none */ }
        const t = setTimeout(() => exit(1), exitGraceMs);
        if (t && typeof t.unref === 'function') t.unref();
      };
      if (start === 1 && Number.isInteger(envPid) && envPid > 1) {
        parentGone();
        return;
      }
      watchdogTimer = setInterval(() => {
        let gone = false;
        try { gone = getPpid() !== start; } catch { gone = false; }
        if (!gone) return;
        clearInterval(watchdogTimer);
        watchdogTimer = null;
        parentGone();
      }, watchdogMs);
      if (typeof watchdogTimer.unref === 'function') watchdogTimer.unref();
    }

    // --- flag, lifecycle ----------------------------------------------------------------
    pi.registerFlag(CHILD_FLAG, {
      type: 'boolean', default: false,
      description: 'Internal: marks a Pi started by fablepowers_dispatch (set together with FABLEPOWERS_PARENT_SESSION).',
    });

    pi.on('session_start', async (_event, ctx) => {
      try {
        await init();
        const st = childState();
        if (st.isChild === true) {
          if (!childLogged) {
            childLogged = true;
            logAt(ctx.cwd, `loaded in child seat=${env.FABLEPOWERS_SEAT || '?'} parent=${env.FABLEPOWERS_PARENT_SESSION}; gate ${python ? 'on' : 'off (python3 not found)'}`);
          }
          startWatchdog(ctx);
        }
      } catch (e) { report('session_start', ctx, e); }
    });

    pi.on('session_shutdown', async (_event, ctx) => {
      try {
        if (globalThis[GUARD] === token) delete globalThis[GUARD];
        if (watchdogTimer) { clearInterval(watchdogTimer); watchdogTimer = null; }
        for (const proc of children) terminate(proc);
      } catch (e) { report('session_shutdown', ctx, e); }
    });

    // --- bootstrap ------------------------------------------------------------------------
    pi.on('before_agent_start', async (event, ctx) => {
      try {
        if (childState().isChild === true) return;
        const text = await bootstrapText();
        const opts = event && event.systemPromptOptions;
        if (!opts || typeof opts !== 'object') {
          logAt(ctx && ctx.cwd, 'before_agent_start without systemPromptOptions; no bootstrap');
          return;
        }
        if (!opts.sections || typeof opts.sections !== 'object') opts.sections = {};
        opts.sections[SECTION] = text;
      } catch (e) { report('before_agent_start', ctx, e); }
    });

    // --- gate adapter -------------------------------------------------------------------
    pi.on('tool_call', async (event, ctx) => {
      try {
        const tool = event.toolName;
        const input = event.input && typeof event.input === 'object' ? event.input : null;
        if (tool === 'fablepowers_dispatch' || tool === 'subagent') {
          const fields = tool === 'fablepowers_dispatch'
            ? { tool, seat: input && typeof input.seat === 'string' ? input.seat : null }
            : { tool, agent: input && typeof input.agent === 'string' ? input.agent : null };
          return denyOf(await gate('dispatch', ctx, fields));
        }
        if (tool !== 'write' && tool !== 'edit') return undefined; // SF2: reads are never gated
        const raw = input ? input.path : undefined;
        let abs = null;
        if (typeof raw === 'string' && raw) {
          try {
            abs = resolveToCwd(raw, ctx.cwd, home);
            input.path = abs; // Q-G1: the tool writes exactly the path the gate checked
          } catch (e) {
            logAt(ctx.cwd, `${tool} path ${JSON.stringify(raw)} could not be resolved (${e && e.message}); sent to the gate as is`);
          }
        }
        if (tool === 'write' && abs && typeof event.toolCallId === 'string') {
          let ex = true;
          try { fs.lstatSync(abs); } catch (e) { ex = !(e && e.code === 'ENOENT'); }
          if (existed.size >= EXISTED_MAX) existed.delete(existed.keys().next().value);
          existed.set(event.toolCallId, ex);
        }
        // a blocked call gets no tool_result; its existed entry ages out of the bounded map
        return denyOf(await gate('tool_call', ctx, { tool, path: abs ?? (typeof raw === 'string' ? raw : null) }));
      } catch (e) {
        report('tool_call', ctx, e);
        return undefined;
      }
    });

    pi.on('tool_result', async (event, ctx) => {
      try {
        const id = typeof event.toolCallId === 'string' ? event.toolCallId : null;
        const ex = id !== null ? existed.get(id) : undefined;
        if (id !== null) existed.delete(id);
        if (event.toolName !== 'write') return undefined;
        const input = event.input && typeof event.input === 'object' ? event.input : {};
        const fields = { tool: 'write', path: typeof input.path === 'string' ? input.path : null, is_error: event.isError };
        if (ex !== undefined) fields.existed = ex;
        const out = await gate('tool_result', ctx, fields);
        if (typeof out.context === 'string' && out.context) {
          const content = Array.isArray(event.content) ? event.content : [];
          return { content: [...content, { type: 'text', text: out.context }] };
        }
        return undefined;
      } catch (e) {
        report('tool_result', ctx, e);
        return undefined;
      }
    });

    // --- commands -----------------------------------------------------------------------
    for (const verb of ['approve', 'withdraw']) {
      pi.registerCommand(`fablepowers:${verb}`, {
        description: verb === 'approve'
          ? 'Record your approval of the pending fablepowers design (/fablepowers:approve [spec key or path]).'
          : 'Withdraw a pending fablepowers design you abandoned (/fablepowers:withdraw [spec key or path]).',
        handler: async (args, ctx) => {
          const notRecorded = (why) => `fablepowers approval gate: \`/fablepowers:${verb}\` may not have been recorded: ${why}. Run \`/fablepowers:${verb}\` again (details in .fablepowers/gate.log).`;
          let text;
          let failed = false;
          try {
            await init();
            if (!python) {
              text = `fablepowers approval gate disabled: python3 not found, so \`/fablepowers:${verb}\` recorded nothing. Install Python 3.8+ (or set FABLEPOWERS_PYTHON) and restart Pi.`;
              failed = true;
            } else {
              const out = await gate('command', ctx, { verb, args: typeof args === 'string' ? args.trim() : '' });
              if (typeof out.context === 'string' && out.context) text = out.context;
              else { text = notRecorded(out[GATE_FAILED] || 'the gate gave no answer'); failed = true; }
            }
          } catch (e) {
            report(`command ${verb}`, ctx, e);
            text = notRecorded(`the extension hit an error (${e && e.message ? e.message : e})`);
            failed = true;
          }
          deliver(ctx, text, failed);
        },
      });
    }

    // --- approval tool (MF3, Q-A3) ------------------------------------------------------
    async function askApproval(ctx, signal) {
      await init();
      if (!python) return { text: 'fablepowers approval gate disabled: python3 not found, so nothing can be recorded. Tell the user to install Python 3.8+ (or set FABLEPOWERS_PYTHON) and restart Pi.' };
      const out = await gate('pending', ctx, {});
      const list = Array.isArray(out.pending)
        ? out.pending.filter((p) => p && typeof p.key === 'string' && p.key && typeof p.spec === 'string' && p.spec) : null;
      if (!list || typeof out.refused !== 'boolean') {
        return { text: `fablepowers approval gate: could not list the pending designs (${out[GATE_FAILED] || 'unexpected answer'}), so no dialog was shown and nothing was recorded. Ask the user to run \`/fablepowers:approve\` in Pi.` };
      }
      if (out.refused) return { text: typeof out.reason === 'string' && out.reason ? out.reason : 'fablepowers approval gate: approvals are refused in this session; nothing was asked or recorded.' };
      if (list.length === 0) return { text: typeof out.reason === 'string' && out.reason ? out.reason : 'fablepowers approval gate: no design is pending, so there is nothing to approve.' };
      if (!ctx.hasUI || !ctx.ui || typeof ctx.ui.select !== 'function') {
        const k = list.length === 1 ? list[0].key : '<key>';
        return { text: `fablepowers approval gate: no UI in this mode, so no dialog was shown and nothing was recorded. Ask the user to run \`/fablepowers:approve ${k}\` in Pi (typed by the user, not through your shell), then end your turn.` };
      }
      const options = list.length === 1
        ? ['Approve', 'Changes needed']
        : [...list.map((p) => `Approve ${p.spec}`), 'Changes needed'];
      const title = list.length === 1
        ? `fablepowers: approve the design ${list[0].spec}?`
        : 'fablepowers: approve which pending design?';
      const answer = await ctx.ui.select(title, options, signal ? { signal } : undefined);
      let choice = null;
      let key = list.length === 1 ? list[0].key : null;
      if (answer === 'Changes needed') choice = 'Changes needed';
      else if (list.length === 1 && answer === 'Approve') choice = 'Approve';
      else if (list.length > 1 && options.indexOf(answer) >= 0) { choice = 'Approve'; key = list[options.indexOf(answer)].key; }
      else if (answer !== undefined && answer !== null) choice = String(answer);
      const res = await gate('approval_tool', ctx, { choice, pending_key: key });
      if (typeof res.context === 'string' && res.context) return { text: res.context, details: { choice, pending_key: key } };
      return { text: `fablepowers approval gate: the answer (${choice}) may not have been recorded: ${res[GATE_FAILED] || 'the gate gave no answer'}. Ask the user to run \`/fablepowers:approve\` in Pi.`, details: { choice, pending_key: key } };
    }

    pi.registerTool({
      name: 'fablepowers_ask_approval',
      label: 'fablepowers approval',
      description: 'Ask the user to approve the pending fablepowers design. Shows the user an Approve / Changes needed dialog naming the design(s) the approval gate reports pending, and records the user\'s answer. The `spec` argument is informational only. Without a UI (print mode) it says to ask the user to run /fablepowers:approve.',
      parameters: {
        type: 'object',
        properties: { spec: { type: 'string', description: 'The spec you are asking about (informational; the dialog shows what is actually pending).' } },
        additionalProperties: false,
      },
      async execute(_toolCallId, _params, signal, _onUpdate, ctx) {
        let r;
        try {
          r = await askApproval(ctx, signal);
        } catch (e) {
          report('fablepowers_ask_approval', ctx, e);
          r = { text: `fablepowers approval gate: the approval tool hit an error (${e && e.message ? e.message : e}); nothing was recorded. Ask the user to run \`/fablepowers:approve\` in Pi.` };
        }
        return { content: [{ type: 'text', text: r.text }], details: r.details || {} };
      },
    });

    // --- dispatch tool (derived from Pi's subagent example; see NOTICE) -------------------

    // Q-D11 / SF11: an explicit cwd must resolve (realpath) inside the parent's git
    // toplevel or one of its linked worktrees.
    function childCwd(requested, ctx) {
      if (requested === undefined || requested === null || requested === '') return { cwd: ctx.cwd };
      if (typeof requested !== 'string') return { error: 'cwd must be a string' };
      let real;
      try {
        real = fs.realpathSync(resolveToCwd(requested, ctx.cwd, home));
        if (!fs.statSync(real).isDirectory()) return { error: `cwd \`${requested}\` is not a directory` };
      } catch (e) {
        return { error: `cwd \`${requested}\` does not exist (${e && e.code ? e.code : e})` };
      }
      const top = findToplevel(ctx.cwd);
      if (!top) return { error: 'an explicit cwd needs the session to be inside a git repository' };
      const roots = new Set([top]);
      const r = spawnSync('git', ['-C', top, 'worktree', 'list', '--porcelain'], { encoding: 'utf8', timeout: 2000, env });
      if (r.status === 0 && typeof r.stdout === 'string') {
        for (const line of r.stdout.split('\n')) {
          if (!line.startsWith('worktree ')) continue;
          try { roots.add(fs.realpathSync(line.slice(9))); } catch { /* gone */ }
        }
      }
      for (const root of roots) if (under(real, root)) return { cwd: real };
      return { error: `cwd \`${requested}\` (${real}) is outside this repository and its worktrees` };
    }

    function childDir(ctx, parentId) {
      let file = null;
      let dir = null;
      try { file = ctx.sessionManager.getSessionFile(); } catch { file = null; }
      try { dir = ctx.sessionManager.getSessionDir(); } catch { dir = null; }
      // Q-D5: under the parent's session directory; a --no-session parent has no
      // session file, so its children go under the temp directory.
      const base = typeof file === 'string' && file
        ? (typeof dir === 'string' && dir ? dir : path.dirname(file))
        : tmpRoot;
      return path.join(base, 'fablepowers-children', parentId);
    }

    function runChild(invocation, cwd, childEnv, signal, expected) {
      return new Promise((resolve) => {
        const res = {
          exitCode: 0, signal: null, sessionId: null, model: null, thinking: null, text: '',
          stopReason: null, errorMessage: null, stderr: '', spawnError: null, aborted: false,
          usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, turns: 0 },
        };
        let proc;
        try {
          proc = spawnFn(invocation.command, invocation.args, { cwd, env: childEnv, shell: false, stdio: ['ignore', 'pipe', 'pipe'] });
        } catch (e) {
          res.exitCode = 1;
          res.spawnError = String(e && e.message ? e.message : e);
          resolve(res);
          return;
        }
        children.add(proc);
        let finished = false;
        let kill = null;
        const finish = (code, sig) => {
          if (finished) return;
          finished = true;
          children.delete(proc);
          if (kill && signal) signal.removeEventListener('abort', kill);
          if (buffer.trim()) onLine(buffer);
          res.exitCode = code ?? 1;
          res.signal = sig || null;
          resolve(res);
        };
        let buffer = '';
        const onLine = (line) => {
          if (!line.trim()) return;
          let ev;
          try { ev = JSON.parse(line); } catch { return; }
          if (!ev || typeof ev !== 'object') return;
          if (ev.type === 'session' && typeof ev.id === 'string' && res.sessionId === null) res.sessionId = ev.id;
          if (ev.type === 'message_end' && ev.message && ev.message.role === 'assistant') {
            const m = ev.message;
            res.usage.turns++;
            const u = m.usage || {};
            res.usage.input += u.input || 0;
            res.usage.output += u.output || 0;
            res.usage.cacheRead += u.cacheRead || 0;
            res.usage.cacheWrite += u.cacheWrite || 0;
            res.usage.cost += (u.cost && u.cost.total) || 0;
            if (res.model === null && typeof m.provider === 'string' && typeof m.model === 'string') {
              res.model = `${m.provider}/${m.model}`;
              res.thinking = typeof m.thinkingLevel === 'string' ? m.thinkingLevel : null;
              if (expected && expected.model && res.model !== expected.model) {
                expected.onMismatch(`the child reported model ${res.model}, not the seat's ${expected.model}`);
              } else if (expected && expected.thinking && res.thinking !== null && res.thinking !== expected.thinking) {
                expected.onMismatch(`the child reported thinking ${res.thinking}, not the seat's ${expected.thinking}`);
              }
            }
            const t = lastText(m);
            if (t) res.text = t; // N4: keep only the latest assistant text
            if (typeof m.stopReason === 'string') res.stopReason = m.stopReason;
            if (typeof m.errorMessage === 'string') res.errorMessage = m.errorMessage;
          }
        };
        proc.stdout.on('data', (d) => {
          buffer += d.toString();
          const lines = buffer.split('\n');
          buffer = lines.pop() || '';
          if (buffer.length > LINE_MAX) buffer = '';
          for (const l of lines) onLine(l);
        });
        proc.stderr.on('data', (d) => {
          res.stderr = (res.stderr + d.toString()).slice(-STDERR_TAIL);
        });
        proc.on('error', (e) => {
          res.spawnError = String(e && e.message ? e.message : e);
          if (proc.pid === undefined) finish(1, null); // never started: no 'close' follows
        });
        proc.on('close', (code, sig) => finish(code, sig));
        if (signal) {
          kill = () => { res.aborted = true; terminate(proc); };
          if (signal.aborted) kill();
          else signal.addEventListener('abort', kill, { once: true });
        }
      });
    }

    async function dispatch(params, signal, ctx) {
      const st = childState();
      if (st.isChild !== false || st.envSet) {
        return { error: 'fablepowers_dispatch is not available in a dispatched child session (no sub-dispatch); do the work yourself or report back to the parent.' };
      }
      const seat = params && params.seat;
      if (typeof seat !== 'string' || !Object.prototype.hasOwnProperty.call(SEATS, seat)) {
        return { error: `unknown seat ${JSON.stringify(seat)}; use one of ${Object.keys(SEATS).join(', ')}` };
      }
      const task = params.task;
      if (typeof task !== 'string' || !task.trim()) return { error: 'the task is empty' };
      const where = childCwd(params.cwd, ctx);
      if (where.error) return { error: `dispatch rejected: ${where.error}` };
      await init();

      const pinned = seats[seat];
      let model = null;
      let thinking = null;
      if (pinned) {
        model = `${pinned.provider}/${pinned.id}`;
        thinking = pinned.thinking;
      } else {
        if (ctx.model && typeof ctx.model.provider === 'string' && typeof ctx.model.id === 'string') model = `${ctx.model.provider}/${ctx.model.id}`;
        let t = ctx.thinkingLevel;
        if (t === undefined) { try { t = pi.getThinkingLevel(); } catch { t = undefined; } }
        thinking = THINKING_LEVELS.has(t) ? t : null;
      }

      const parentId = sessionId(ctx) || `pid-${process.pid}`;
      const dir = childDir(ctx, parentId);
      fs.mkdirSync(dir, { recursive: true });
      const tmp = fs.mkdtempSync(path.join(tmpRoot, 'fablepowers-dispatch-'));
      try {
        // Q-D1: the role prompt with its frontmatter stripped, in a temp file.
        const roleFile = path.join(ROOT, 'agents', SEATS[seat]);
        const role = stripFrontmatter(fs.readFileSync(roleFile, 'utf8')).body.trim();
        const head = `You are the fablepowers ${seat.replace('_', '-')} seat, dispatched by fablepowers_dispatch from a parent Pi session. Plugin root: \`${ROOT}\`; a skill written \`fablepowers:<x>\` is the Pi skill \`fablepowers-<x>\`. You cannot dispatch other seats. Your role instructions follow (source: \`${roleFile}\`).`;
        const promptFile = path.join(tmp, `role-${seat}.md`);
        fs.writeFileSync(promptFile, `${head}\n\n${role}\n`, { mode: 0o600 });
        let taskArg = `Task: ${task}`;
        if (Buffer.byteLength(task, 'utf8') > TASK_INLINE_MAX) {
          const taskFile = path.join(tmp, 'task.md');
          fs.writeFileSync(taskFile, task, { mode: 0o600 });
          taskArg = `Task: read ${taskFile} and do the task it describes.`;
        }
        // `--fablepowers-child=1`: a bare boolean flag would swallow a following
        // non-dash argument (Task 0 item 3).
        const args = ['--mode', 'json', '-p', '--session-dir', dir, '-e', ROOT, `--${CHILD_FLAG}=1`];
        if (model) args.push('--model', model);
        if (thinking) args.push('--thinking', thinking);
        args.push('--append-system-prompt', promptFile, taskArg);
        const childEnv = {
          ...env,
          FABLEPOWERS_PARENT_SESSION: parentId,
          FABLEPOWERS_SEAT: seat,
          FABLEPOWERS_PARENT_PID: String(process.pid),
        };
        const warnings = [];
        const expected = pinned ? { model, thinking, onMismatch: (w) => warnings.push(w) } : null;
        const res = await runChild(piInvocation(args), where.cwd, childEnv, signal, expected);
        let sessionFile = null;
        if (res.sessionId) {
          try {
            const f = fs.readdirSync(dir).find((n) => n.endsWith(`${res.sessionId}.jsonl`));
            if (f) sessionFile = path.join(dir, f);
          } catch { /* none */ }
        }
        try {
          pi.appendEntry(CHILD_ENTRY, { seat, childSessionId: res.sessionId, childSessionFile: sessionFile, childSessionDir: dir, model: res.model || model, exitCode: res.exitCode });
        } catch (e) { report('fablepowers_dispatch link entry', ctx, e); }
        if (res.aborted) throw new Error(`fablepowers_dispatch (${seat}) was aborted; the child was stopped.`);
        const failed = res.exitCode !== 0 || res.stopReason === 'error' || res.stopReason === 'aborted' || res.spawnError !== null;
        if (res.spawnError) warnings.push(`the child could not be run: ${res.spawnError}`);
        if (res.exitCode !== 0) warnings.push(`the child exited with code ${res.exitCode}${res.signal ? ` (${res.signal})` : ''}`);
        if (res.stopReason === 'error' || res.stopReason === 'aborted') warnings.push(`the child's last turn stopped with ${res.stopReason}${res.errorMessage ? `: ${res.errorMessage}` : ''}`);
        if (failed && res.stderr.trim()) warnings.push(`child stderr (tail): ${res.stderr.trim()}`);
        const shownModel = res.model || model || 'the session default';
        const footer = `[fablepowers_dispatch: seat ${seat}${pinned ? '' : ' (unpinned: session model)'}, model ${shownModel}${res.thinking || thinking ? `, thinking ${res.thinking || thinking}` : ''}, exit ${res.exitCode}${sessionFile ? `, child session ${sessionFile}` : ''}]`;
        const text = [
          ...warnings.map((w) => `Warning: ${w}`),
          capOutput(res.text || '(no output)', OUTPUT_CAP, sessionFile),
          footer,
        ].join('\n\n');
        return {
          text, failed,
          details: { seat, model: res.model || model, usage: res.usage, exitCode: res.exitCode, childSessionFile: sessionFile },
        };
      } finally {
        try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* ignore */ }
      }
    }

    pi.registerTool({
      name: 'fablepowers_dispatch',
      label: 'fablepowers dispatch',
      description: 'Dispatch a fablepowers seat (implementer, strict_implementer or reviewer) as a separate Pi process on the seat\'s pinned model, with the role prompt from agents/<seat>.md. One task per call; calls run one at a time. Returns the child\'s final answer, model, usage and exit code.',
      parameters: {
        type: 'object',
        properties: {
          seat: { type: 'string', enum: Object.keys(SEATS), description: 'The seat to dispatch.' },
          task: { type: 'string', description: 'The complete, self-contained task for the seat.' },
          cwd: { type: 'string', description: 'Optional working directory: inside this repository or one of its linked worktrees.' },
        },
        required: ['seat', 'task'],
        additionalProperties: false,
      },
      executionMode: 'sequential',
      async execute(_toolCallId, params, signal, _onUpdate, ctx) {
        let r;
        try {
          r = await dispatch(params, signal, ctx);
        } catch (e) {
          if (signal && signal.aborted) throw e;
          report('fablepowers_dispatch', ctx, e);
          r = { error: `fablepowers_dispatch failed: ${e && e.message ? e.message : e}` };
        }
        if (r.error) return { content: [{ type: 'text', text: r.error }], details: {}, isError: true };
        return { content: [{ type: 'text', text: r.text }], details: r.details, ...(r.failed ? { isError: true } : {}) };
      },
    });
  };
}

// Helpers for the test suite (tests/pi/extension.test.mjs); not extension API.
createExtension.internals = {
  GUARD, SEATS, SECTION, RESULT_TYPE, CHILD_FLAG, OUTPUT_CAP, TASK_INLINE_MAX,
  stripFrontmatter, resolveToCwd, piInvocationFor, capOutput, findPython,
};

export default createExtension();
